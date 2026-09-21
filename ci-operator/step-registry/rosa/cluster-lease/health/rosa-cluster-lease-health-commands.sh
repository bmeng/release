#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

LEASE_NAMESPACE="${LEASE_NAMESPACE:-rosa-cluster-lease}"
LEASE_HOST_KUBECONFIG="/etc/rosa-cluster-lease-manager/kubeconfig"
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-staging}"

if [[ ! -f "${LEASE_HOST_KUBECONFIG}" ]]; then
    log "ERROR: Lease host kubeconfig not found at ${LEASE_HOST_KUBECONFIG}"
    exit 1
fi

lease_oc() {
    oc --kubeconfig="${LEASE_HOST_KUBECONFIG}" "$@"
}

SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials found in cluster profile"
    exit 1
fi

CURRENT_OCM_ENV="${OCM_LOGIN_ENV}"

ocm_ensure_env() {
    local target_env="$1"
    if [[ "${CURRENT_OCM_ENV}" == "${target_env}" ]]; then
        return 0
    fi
    if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
        ocm login --url "${target_env}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
    elif [[ -n "${OCM_TOKEN}" ]]; then
        ocm login --url "${target_env}" --token "${OCM_TOKEN}"
    fi
    CURRENT_OCM_ENV="${target_env}"
}

publish_health() {
    local cm_name="$1"
    local health_status="$2"
    local health_reason="$3"
    local checked_at patch

    checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    patch=$(jq -nc \
        --arg status "${health_status}" \
        --arg reason "${health_reason}" \
        --arg checkedAt "${checked_at}" \
        '{metadata:{annotations:{
            "rosa-cluster-lease/health-status":$status,
            "rosa-cluster-lease/health-reason":$reason,
            "rosa-cluster-lease/health-checked-at":$checkedAt
        }}}')

    if ! lease_oc patch configmap "${cm_name}" -n "${LEASE_NAMESPACE}" --type merge -p "${patch}" >/dev/null; then
        log "WARNING: Failed to publish health result for ${cm_name}"
        return 1
    fi
}

ALL_CMS=$(lease_oc get configmap -n "${LEASE_NAMESPACE}" -l "rosa-cluster-lease/managed=true" -o json)
TOTAL=$(echo "${ALL_CMS}" | jq '.items | length')

log "Lease health check: ${TOTAL} cluster(s) in inventory"

HEALTHY=0
UNHEALTHY=0
UNKNOWN=0
SKIPPED=0
REPAIRED=0

REPORT="${ARTIFACT_DIR}/lease-health-report.txt"
echo "Lease Health Report - $(date -u)" > "${REPORT}"
echo "================================" >> "${REPORT}"

for i in $(seq 0 $((TOTAL - 1))); do
    CM=$(echo "${ALL_CMS}" | jq ".items[${i}]")
    CM_NAME=$(echo "${CM}" | jq -r '.metadata.name')
    CLUSTER_ID=$(echo "${CM}" | jq -r '.data["cluster-id"]')
    STATUS=$(echo "${CM}" | jq -r '.metadata.labels["rosa-cluster-lease/status"]')
    HOLDER=$(echo "${CM}" | jq -r '.metadata.annotations["rosa-cluster-lease/holder"] // ""')

    echo "" >> "${REPORT}"
    echo "Cluster: ${CM_NAME} (${CLUSTER_ID})" >> "${REPORT}"
    echo "  Status: ${STATUS}" >> "${REPORT}"

    if [[ "${STATUS}" == "in-use" ]]; then
        log "SKIPPED: ${CM_NAME} is in-use by ${HOLDER}"
        echo "  Skipped: active lease held by ${HOLDER}" >> "${REPORT}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    if [[ "${STATUS}" == "provisioning" || "${STATUS}" == "maintenance" ]]; then
        log "SKIPPED: ${CM_NAME} has lifecycle status ${STATUS}"
        echo "  Skipped: lifecycle status ${STATUS}" >> "${REPORT}"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    CLUSTER_OCM_ENV=$(echo "${CM}" | jq -r '.data["ocm-env"] // "staging"')
    ocm_ensure_env "${CLUSTER_OCM_ENV}"

    OCM_STATUS=$(ocm get /api/clusters_mgmt/v1/clusters/"${CLUSTER_ID}" 2>/dev/null | jq -r '.status.state // "unknown"' 2>/dev/null || echo "unreachable")
    echo "  OCM status: ${OCM_STATUS}" >> "${REPORT}"

    if [[ "${OCM_STATUS}" == "unreachable" || "${OCM_STATUS}" == "unknown" ]]; then
        log "UNKNOWN: ${CM_NAME} OCM status could not be determined"
        publish_health "${CM_NAME}" "unknown" "OCM status could not be determined" || true
        UNKNOWN=$((UNKNOWN + 1))
        continue
    elif [[ "${OCM_STATUS}" != "ready" ]]; then
        log "UNHEALTHY: ${CM_NAME} OCM status is ${OCM_STATUS}"
        publish_health "${CM_NAME}" "unhealthy" "OCM status: ${OCM_STATUS}" || true
        UNHEALTHY=$((UNHEALTHY + 1))
        continue
    fi

    # Fetch one cluster-admin kubeconfig for RBAC, PKO repair, and package checks.
    CLUSTER_KUBECONFIG=$(mktemp)
    if ! ocm get "/api/clusters_mgmt/v1/clusters/${CLUSTER_ID}/credentials" 2>/dev/null | jq -r '.kubeconfig // empty' > "${CLUSTER_KUBECONFIG}" 2>/dev/null || [[ ! -s "${CLUSTER_KUBECONFIG}" ]]; then
        log "UNKNOWN: ${CM_NAME} could not fetch cluster kubeconfig from OCM"
        publish_health "${CM_NAME}" "unknown" "Could not fetch cluster kubeconfig" || true
        rm -f "${CLUSTER_KUBECONFIG}"
        UNKNOWN=$((UNKNOWN + 1))
        continue
    fi

    RBAC_RESULT=$(oc auth can-i create configmaps \
        --as=dedicated-admin-check --as-group=dedicated-admins \
        -n dedicated-admin --request-timeout=30s \
        --kubeconfig="${CLUSTER_KUBECONFIG}" 2>&1) || true
    if [[ "${RBAC_RESULT}" == "no" ]]; then
        log "UNHEALTHY: ${CM_NAME} dedicated-admins permissions are not functional"
        publish_health "${CM_NAME}" "unhealthy" "RBAC: dedicated-admins permissions not functional" || true
        rm -f "${CLUSTER_KUBECONFIG}"
        UNHEALTHY=$((UNHEALTHY + 1))
        continue
    elif [[ "${RBAC_RESULT}" != "yes" ]]; then
        log "UNKNOWN: ${CM_NAME} RBAC check was inconclusive"
        publish_health "${CM_NAME}" "unknown" "RBAC check was inconclusive" || true
        rm -f "${CLUSTER_KUBECONFIG}"
        UNKNOWN=$((UNKNOWN + 1))
        continue
    fi

    # Keep the existing limited PKO repair in the health job: fix CRDs whose
    # instance label no longer matches the package reporting refusing adoption.
    STUCK_PKGS=$(oc get clusterpackage -l "hive.openshift.io/managed=true" \
        -o json --kubeconfig="${CLUSTER_KUBECONFIG}" 2>/dev/null \
        | jq -r '.items[] as $pkg |
            [$pkg.status.conditions[]? |
                select((.message // "") | contains("refusing adoption")) |
                .message][0] as $message |
            select($message != null) |
            $pkg.metadata.name + "|" + $message' 2>/dev/null) || true
    PKO_REPAIR_FAILED=false
    if [[ -n "${STUCK_PKGS}" ]]; then
        while IFS='|' read -r PKG_NAME PKG_MSG; do
            [[ -z "${PKG_NAME}" ]] && continue
            CRD_NAME=$(echo "${PKG_MSG}" | sed -n 's|.*object /\([^ ]*\) kind:CustomResourceDefinition.*|\1|p')
            if [[ -z "${CRD_NAME}" ]]; then
                log "WARNING: ${CM_NAME} could not parse CRD name from PKO error: ${PKG_MSG}"
                PKO_REPAIR_FAILED=true
                continue
            fi
            CRD_INSTANCE=$(oc get crd "${CRD_NAME}" \
                -o jsonpath='{.metadata.labels.package-operator\.run/instance}' \
                --kubeconfig="${CLUSTER_KUBECONFIG}" 2>/dev/null || true)
            if [[ "${CRD_INSTANCE}" != "${PKG_NAME}" ]]; then
                log "Repairing CRD ${CRD_NAME} ownership: instance=${CRD_INSTANCE:-<empty>} -> ${PKG_NAME}"
                if oc patch crd "${CRD_NAME}" --type merge \
                    -p '{"metadata":{"ownerReferences":[],"labels":{"package-operator.run/instance":"'"${PKG_NAME}"'"}}}' \
                    --kubeconfig="${CLUSTER_KUBECONFIG}" >/dev/null; then
                    REPAIRED=$((REPAIRED + 1))
                else
                    PKO_REPAIR_FAILED=true
                fi
            fi
        done <<< "${STUCK_PKGS}"
    fi

    CLUSTER_TYPE=$(echo "${CM}" | jq -r '.data["cluster-type"] // "classic-sts"')
    EXPECTED_CPS=$(lease_oc get configmap rosa-cluster-lease-config -n "${LEASE_NAMESPACE}" -o jsonpath="{.data['expected-clusterpackages-${CLUSTER_TYPE}']}" 2>/dev/null || true)
    if [[ -z "${EXPECTED_CPS}" ]]; then
        EXPECTED_CPS=$(lease_oc get configmap rosa-cluster-lease-config -n "${LEASE_NAMESPACE}" -o jsonpath='{.data.expected-clusterpackages}' 2>/dev/null || true)
    fi
    if [[ -z "${EXPECTED_CPS}" ]]; then
        EXPECTED_CPS="configure-alertmanager-operator managed-node-metadata-operator managed-upgrade-operator ocm-agent-operator osd-metrics-exporter rbac-permissions-operator route-monitor-operator splunk-forwarder-operator"
    fi

    ACTUAL_CP_JSON=$(oc --kubeconfig="${CLUSTER_KUBECONFIG}" get clusterpackage \
        -l "hive.openshift.io/managed=true" --request-timeout=15s -o json 2>/dev/null) || true
    if [[ -z "${ACTUAL_CP_JSON}" ]]; then
        log "UNKNOWN: ${CM_NAME} could not list ClusterPackages"
        publish_health "${CM_NAME}" "unknown" "Could not list ClusterPackages" || true
        rm -f "${CLUSTER_KUBECONFIG}"
        UNKNOWN=$((UNKNOWN + 1))
        continue
    fi

    ACTUAL_CP_NAMES=$(echo "${ACTUAL_CP_JSON}" | jq -r '.items[].metadata.name' 2>/dev/null | sort) || true
    CP_ISSUES=""
    for expected_cp in ${EXPECTED_CPS}; do
        if ! echo "${ACTUAL_CP_NAMES}" | grep -qx "${expected_cp}"; then
            CP_ISSUES="${CP_ISSUES}missing:${expected_cp} "
        fi
    done
    DEGRADED_CPS=$(echo "${ACTUAL_CP_JSON}" | jq -r '
        .items[] |
        select(any(.status.conditions[]?;
            .type == "Available" and .status == "True") | not) |
        .metadata.name' 2>/dev/null) || true
    for degraded_cp in ${DEGRADED_CPS}; do
        CP_ISSUES="${CP_ISSUES}degraded:${degraded_cp} "
    done
    if [[ "${PKO_REPAIR_FAILED}" == "true" ]]; then
        CP_ISSUES="${CP_ISSUES}repair-failed "
    fi

    rm -f "${CLUSTER_KUBECONFIG}"
    if [[ -n "${CP_ISSUES}" ]]; then
        CP_ISSUES="${CP_ISSUES% }"
        log "UNHEALTHY: ${CM_NAME} ClusterPackage issues: ${CP_ISSUES}"
        echo "  ClusterPackage issues: ${CP_ISSUES}" >> "${REPORT}"
        publish_health "${CM_NAME}" "unhealthy" "ClusterPackage: ${CP_ISSUES}" || true
        UNHEALTHY=$((UNHEALTHY + 1))
        continue
    fi

    publish_health "${CM_NAME}" "healthy" "" || true
    HEALTHY=$((HEALTHY + 1))
done

echo "" >> "${REPORT}"
echo "Summary: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${UNKNOWN} unknown, ${SKIPPED} skipped, ${REPAIRED} repaired" >> "${REPORT}"

log "Lease health check complete: ${HEALTHY} healthy, ${UNHEALTHY} unhealthy, ${UNKNOWN} unknown, ${SKIPPED} skipped, ${REPAIRED} repaired"
cat "${REPORT}"
