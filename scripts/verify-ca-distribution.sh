#!/bin/bash

# Script to verify CA bundle distribution across all clusters

set -euo pipefail

CA_BUNDLE_CONFIGMAP_NAME="${CA_BUNDLE_CONFIGMAP_NAME:-vp-pattern-proxy-ca-bundle}"
PATTERN_APP_NAMESPACE="${PATTERN_APP_NAMESPACE:-ramendr-starter-kit-odf}"

echo "CA Bundle Distribution Verification"
echo "==================================="

# Function to check hub cluster
check_hub_cluster() {
    echo "1. Checking Hub Cluster:"
    echo "========================"

    if oc get configmap "$CA_BUNDLE_CONFIGMAP_NAME" -n openshift-config >/dev/null 2>&1; then
        local cert_count
        cert_count=$(oc get configmap "$CA_BUNDLE_CONFIGMAP_NAME" -n openshift-config -o jsonpath="{.data['ca-bundle\.crt']}" | grep -c 'BEGIN CERTIFICATE' 2>/dev/null || echo "0")
        echo "✓ Hub cluster ConfigMap ${CA_BUNDLE_CONFIGMAP_NAME} exists with $cert_count certificates"
    else
        echo "✗ Hub cluster ConfigMap ${CA_BUNDLE_CONFIGMAP_NAME} not found"
        return 1
    fi

    if oc get bundle "$CA_BUNDLE_CONFIGMAP_NAME" -n openshift-config >/dev/null 2>&1; then
        local bundle_status
        bundle_status=$(oc get bundle "$CA_BUNDLE_CONFIGMAP_NAME" -n openshift-config -o jsonpath='{.status.conditions[?(@.type=="Synced")].status}' 2>/dev/null || echo "Unknown")
        echo "✓ trust-manager Bundle ${CA_BUNDLE_CONFIGMAP_NAME} status: ${bundle_status:-Unknown}"
    else
        echo "⚠️  trust-manager Bundle ${CA_BUNDLE_CONFIGMAP_NAME} not found"
    fi

    local proxy_ca
    proxy_ca=$(oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null || echo "")
    if [[ "$proxy_ca" == "$CA_BUNDLE_CONFIGMAP_NAME" ]]; then
        echo "✓ Hub cluster proxy is configured to use ${CA_BUNDLE_CONFIGMAP_NAME}"
    else
        echo "⚠️  Hub cluster proxy is not using ${CA_BUNDLE_CONFIGMAP_NAME} (current: ${proxy_ca:-<unset>})"
    fi

    echo ""
}

# Function to check managed clusters
check_managed_clusters() {
    echo "2. Checking Managed Clusters:"
    echo "============================="

    local managed_clusters
    managed_clusters=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    if [[ -z "$managed_clusters" ]]; then
        echo "No managed clusters found"
        return 0
    fi

    local total_clusters=0
    local configured_clusters=0

    for cluster in $managed_clusters; do
        if [[ "$cluster" == "local-cluster" ]]; then
            continue
        fi

        ((total_clusters++))
        echo "Checking cluster: $cluster"

        local kubeconfig_file="/tmp/${cluster}-verify-ca-kubeconfig.yaml"
        if ! oc get secret -n "$cluster" -o name 2>/dev/null | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' 2>/dev/null | base64 -d > "$kubeconfig_file"; then
            echo "  ❌ Could not get kubeconfig for $cluster"
            continue
        fi

        if oc --kubeconfig="$kubeconfig_file" get configmap "$CA_BUNDLE_CONFIGMAP_NAME" -n openshift-config >/dev/null 2>&1; then
            local cert_count
            cert_count=$(oc --kubeconfig="$kubeconfig_file" get configmap "$CA_BUNDLE_CONFIGMAP_NAME" -n openshift-config -o jsonpath="{.data['ca-bundle\.crt']}" | grep -c 'BEGIN CERTIFICATE' 2>/dev/null || echo "0")
            echo "  ✓ ConfigMap ${CA_BUNDLE_CONFIGMAP_NAME} exists with $cert_count certificates"
            ((configured_clusters++))
        else
            echo "  ✗ ConfigMap ${CA_BUNDLE_CONFIGMAP_NAME} not found"
        fi

        local proxy_ca
        proxy_ca=$(oc --kubeconfig="$kubeconfig_file" get proxy cluster -o jsonpath='{.spec.trustedCA.name}' 2>/dev/null || echo "")
        if [[ "$proxy_ca" == "$CA_BUNDLE_CONFIGMAP_NAME" ]]; then
            echo "  ✓ Proxy uses ${CA_BUNDLE_CONFIGMAP_NAME}"
        else
            echo "  ⚠️  Proxy trustedCA is ${proxy_ca:-<unset>}"
        fi

        rm -f "$kubeconfig_file"
    done

    echo ""
    echo "Summary: $configured_clusters/$total_clusters managed clusters have ${CA_BUNDLE_CONFIGMAP_NAME}"
    echo ""
}

# Function to check vp-manage-proxy-cluster-ca GitOps app
check_vp_manage_proxy_ca_app() {
    echo "3. Checking vp-manage-proxy-cluster-ca Application:"
    echo "==================================================="

    if oc get application vp-manage-proxy-cluster-ca -n "$PATTERN_APP_NAMESPACE" >/dev/null 2>&1; then
        local sync_status health_status
        sync_status=$(oc get application vp-manage-proxy-cluster-ca -n "$PATTERN_APP_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
        health_status=$(oc get application vp-manage-proxy-cluster-ca -n "$PATTERN_APP_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
        echo "✓ Application vp-manage-proxy-cluster-ca: Sync=${sync_status:-Unknown}, Health=${health_status:-Unknown}"
    else
        echo "✗ Application vp-manage-proxy-cluster-ca not found in namespace ${PATTERN_APP_NAMESPACE}"
    fi

    echo ""
}

# Function to check job status
check_job_status() {
    echo "4. Checking vp-manage-proxy-cluster-ca Jobs:"
    echo "============================================="

    if oc get jobs -n vp-manage-proxy-cluster-ca >/dev/null 2>&1; then
        local failed_jobs
        failed_jobs=$(oc get jobs -n vp-manage-proxy-cluster-ca -o jsonpath='{range .items[?(@.status.failed)]}{.metadata.name}{" "}{end}' 2>/dev/null || echo "")
        if [[ -n "$failed_jobs" ]]; then
            echo "⚠️  Failed jobs in vp-manage-proxy-cluster-ca: $failed_jobs"
        else
            echo "✓ No failed jobs in vp-manage-proxy-cluster-ca"
        fi
    else
        echo "⚠️  Namespace vp-manage-proxy-cluster-ca not found or no jobs yet"
    fi

    echo ""
}

# Function to provide recommendations
provide_recommendations() {
    echo "5. Recommendations:"
    echo "==================="
    echo ""
    echo "If issues are found:"
    echo "1. Check hub bundle: oc get configmap ${CA_BUNDLE_CONFIGMAP_NAME} -n openshift-config -o yaml"
    echo "2. Check trust-manager Bundle: oc get bundle ${CA_BUNDLE_CONFIGMAP_NAME} -n openshift-config -o yaml"
    echo "3. Check proxy trustedCA: oc get proxy cluster -o jsonpath='{.spec.trustedCA.name}{\"\\n\"}'"
    echo "4. Re-sync vp-manage-proxy-cluster-ca: oc patch application vp-manage-proxy-cluster-ca -n ${PATTERN_APP_NAMESPACE} --type=merge --patch='{\"operation\":{\"sync\":{\"syncStrategy\":{\"hook\":{}}}}}'"
    echo "5. Merge additional CAs: ${0%/*}/update-ca-bundle.sh add /path/to/ca.crt"
    echo ""
}

# Main execution
main() {
    echo "Starting CA bundle distribution verification..."
    echo "Expected ConfigMap: ${CA_BUNDLE_CONFIGMAP_NAME}"
    echo ""

    check_hub_cluster
    check_managed_clusters
    check_vp_manage_proxy_ca_app
    check_job_status
    provide_recommendations

    echo "Verification completed!"
}

# Show usage if help requested
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [options]"
    echo ""
    echo "Environment variables:"
    echo "  CA_BUNDLE_CONFIGMAP_NAME - Proxy CA ConfigMap name (default: vp-pattern-proxy-ca-bundle)"
    echo "  PATTERN_APP_NAMESPACE    - Argo app namespace (default: ramendr-starter-kit-odf)"
    echo ""
    echo "This script verifies CA distribution for the v1.3 vp-manage-proxy-cluster-ca path."
    exit 0
fi

main
