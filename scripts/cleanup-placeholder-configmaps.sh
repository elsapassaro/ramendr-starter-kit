#!/bin/bash

# Script to manually clean up placeholder ConfigMaps from managed clusters
# This addresses the issue where placeholder ConfigMaps were created before the policy was disabled

set -euo pipefail

CA_BUNDLE_CONFIGMAP_NAME="${CA_BUNDLE_CONFIGMAP_NAME:-vp-pattern-proxy-ca-bundle}"

echo "🧹 Cleaning up placeholder ConfigMaps from managed clusters..."

# Get list of managed clusters
MANAGED_CLUSTERS=$(oc get managedclusters -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$MANAGED_CLUSTERS" ]]; then
  echo "No managed clusters found"
  exit 1
fi

echo "Found managed clusters: $MANAGED_CLUSTERS"

for cluster in $MANAGED_CLUSTERS; do
  if [[ "$cluster" == "local-cluster" ]]; then
    continue
  fi
  
  echo "Checking $cluster for placeholder ConfigMaps..."
  
  # Get kubeconfig for the cluster
  KUBECONFIG_FILE=""
  if oc get secret -n "$cluster" -o name | grep -E "(admin-kubeconfig|kubeconfig)" | head -1 | xargs -I {} oc get {} -n "$cluster" -o jsonpath='{.data.kubeconfig}' | base64 -d > "/tmp/${cluster}-kubeconfig.yaml" 2>/dev/null; then
    KUBECONFIG_FILE="/tmp/${cluster}-kubeconfig.yaml"
  fi
  
  if [[ -n "$KUBECONFIG_FILE" && -f "$KUBECONFIG_FILE" ]]; then
    configmap_content=$(oc --kubeconfig="$KUBECONFIG_FILE" get configmap "$CA_BUNDLE_CONFIGMAP_NAME" -n openshift-config -o jsonpath='{.data.ca-bundle\.crt}' 2>/dev/null || echo "")

    if [[ "$configmap_content" == *"Placeholder for ODF SSL certificate bundle"* ]] || [[ "$configmap_content" == *"This will be populated by the certificate extraction job"* ]]; then
      echo "  🗑️  Deleting placeholder ConfigMap ${CA_BUNDLE_CONFIGMAP_NAME} from $cluster..."
      oc --kubeconfig="$KUBECONFIG_FILE" delete configmap "$CA_BUNDLE_CONFIGMAP_NAME" -n openshift-config --ignore-not-found=true
      echo "  ✅ Placeholder ConfigMap removed from $cluster"
    else
      echo "  ✅ $cluster: No placeholder ConfigMap found"
    fi
  else
    echo "  ❌ $cluster: Could not get kubeconfig for cleanup"
  fi
done

echo "✅ Placeholder ConfigMap cleanup completed"
