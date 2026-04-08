#!/bin/bash
set -euo pipefail

#
# RamenDR Starter Kit — Full Environment Redeploy Script
#
# Usage:
#   ./redeploy.sh                    # Full redeploy (hub + pattern)
#   ./redeploy.sh --destroy-only     # Destroy everything without redeploying
#   ./redeploy.sh --pattern-only     # Skip hub install, deploy pattern on existing hub
#   ./redeploy.sh --status           # Check current environment status
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
VALUES_SECRET="${VALUES_SECRET:-$HOME/values-secret.yaml}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z01653801KMZNKX9NGW6G}"
BASE_DOMAIN="ecoengverticals-qe.devcluster.openshift.com"
HUB_REGION="eu-north-1"
SECONDARY_REGION="eu-west-1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)]${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] WARNING:${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ERROR:${NC} $*"; }

check_prerequisites() {
    log "Checking prerequisites..."
    local missing=0
    for cmd in oc openshift-install aws podman git; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Missing: $cmd"
            missing=1
        fi
    done
    if [[ ! -f "$VALUES_SECRET" ]]; then
        err "Missing secrets file: $VALUES_SECRET"
        missing=1
    fi
    if [[ ! -f "$HUB_INSTALL_DIR/install-config.yaml.bak" ]]; then
        err "Missing hub install-config backup: $HUB_INSTALL_DIR/install-config.yaml.bak"
        missing=1
    fi
    if ! podman machine info &>/dev/null; then
        warn "Podman machine not running. Starting..."
        podman machine start 2>/dev/null || true
    fi
    [[ $missing -eq 1 ]] && { err "Prerequisites not met. Aborting."; exit 1; }
    log "All prerequisites met."
}

cleanup_dns() {
    log "Cleaning stale DNS records from Route53..."
    local records
    records=$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --output json 2>/dev/null)
    local stale
    stale=$(echo "$records" | python3 -c "
import json, sys
data = json.load(sys.stdin)
base = '${BASE_DOMAIN}.'
changes = []
for r in data.get('ResourceRecordSets', []):
    name = r['Name']
    rtype = r['Type']
    # Delete A/AAAA records for any subdomain of the base domain (cluster API, ingress, etc.)
    if rtype in ('A', 'AAAA') and name != base:
        changes.append({'Action': 'DELETE', 'ResourceRecordSet': r})
    # Delete TXT records created by the External DNS operator for managed cluster workloads.
    # These are ownership records with names like:
    #   external-dns-*.ocp-primary.<base_domain>.  (TXT)
    #   external-dns-*.ocp-secondary.<base_domain>. (TXT)
    # Leaving them behind causes openshift-install to abort with 'zone already has record sets'.
    elif rtype == 'TXT' and name != base and base in name:
        changes.append({'Action': 'DELETE', 'ResourceRecordSet': r})
if changes:
    print(json.dumps({'Comment': 'Cleanup stale records', 'Changes': changes}))
else:
    print('')
" 2>/dev/null)

    if [[ -n "$stale" ]]; then
        echo "$stale" > /tmp/dns-cleanup-batch.json
        local count
        count=$(python3 -c "import json; d=json.load(open('/tmp/dns-cleanup-batch.json')); print(len(d['Changes']))")
        aws route53 change-resource-record-sets \
            --hosted-zone-id "$HOSTED_ZONE_ID" \
            --change-batch file:///tmp/dns-cleanup-batch.json &>/dev/null
        log "Stale DNS records cleaned ($count records deleted)."
    else
        log "No stale DNS records found."
    fi
}

release_orphaned_eips() {
    log "Releasing orphaned Elastic IPs..."
    for region in "$HUB_REGION" "$SECONDARY_REGION"; do
        local eips
        eips=$(aws ec2 describe-addresses --region "$region" \
            --query 'Addresses[?AssociationId==null].AllocationId' --output text 2>/dev/null)
        for eip in $eips; do
            aws ec2 release-address --region "$region" --allocation-id "$eip" 2>/dev/null
            log "  Released EIP $eip in $region"
        done
    done
}

destroy_hub() {
    log "Destroying hub cluster..."
    if [[ -f "$HUB_INSTALL_DIR/metadata.json" ]]; then
        cd "$HUB_INSTALL_DIR"
        openshift-install destroy cluster --dir . --log-level=info 2>&1 || warn "Hub destroy had errors (may already be destroyed)"
    else
        warn "No hub metadata found — cluster may already be destroyed."
    fi
}

install_hub() {
    log "Preparing hub cluster install directory..."
    cd "$HUB_INSTALL_DIR"
    setopt +o nomatch 2>/dev/null || true
    rm -rf .clusterapi_output .openshift_install.log .openshift_install_state.json \
           auth metadata.json terraform* 2>/dev/null || true
    cp install-config.yaml.bak install-config.yaml

    log "Installing hub cluster (this takes ~45 minutes)..."
    openshift-install create cluster --dir . --log-level=info 2>&1

    log "Hub cluster installed. Setting up kubeconfig..."
    mkdir -p "$HOME/.kube"
    cp "$HUB_INSTALL_DIR/auth/kubeconfig" "$HOME/.kube/config"
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

    log "Hub console: https://console-openshift-console.apps.hub.${BASE_DOMAIN}"
    grep -o 'password: "[^"]*"' "$HUB_INSTALL_DIR/.openshift_install.log" | tail -1 || true
}

scale_hub_workers() {
    log "Scaling hub workers to 6 (required for ODF)..."
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
    for ms in $(oc get machinesets.machine.openshift.io -n openshift-machine-api -o name 2>/dev/null); do
        oc scale "$ms" --replicas=2 -n openshift-machine-api 2>/dev/null
    done

    log "Waiting for workers to be Ready..."
    local tries=0
    while [[ $tries -lt 30 ]]; do
        local ready
        ready=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | grep -c " Ready " || true)
        if [[ "$ready" -ge 5 ]]; then
            log "  $ready workers Ready."
            break
        fi
        log "  $ready/6 workers Ready, waiting..."
        sleep 30
        tries=$((tries + 1))
    done

    log "Labeling workers for ODF storage..."
    for node in $(oc get nodes -l node-role.kubernetes.io/worker -o name 2>/dev/null); do
        oc label "$node" cluster.ocs.openshift.io/openshift-storage="" --overwrite 2>/dev/null
    done
}

deploy_pattern() {
    log "Deploying RamenDR pattern..."
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
    cd "$SCRIPT_DIR"

    log "Running pattern install (this takes ~20 minutes for operators, then ~50 minutes for managed clusters)..."
    VALUES_SECRET="$VALUES_SECRET" ./pattern.sh make install 2>&1 || warn "Pattern install exited with warnings (expected during first sync)"
}

fix_submariner_vxlan_sg() {
    # The Submariner prerequisites job only opens the IPsec ports (UDP 500/4500/4900/ESP/AH).
    # When using the VXLAN cable driver, two additional ports must be opened on each
    # cluster's gateway security group:
    #   UDP 4800  — VXLAN tunnel data
    #   UDP 4490  — Submariner NAT-discovery (used by the VXLAN driver)
    log "Adding VXLAN ports (UDP 4490, 4800) to Submariner gateway security groups..."
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

    for CLUSTER_NAME in ocp-primary ocp-secondary; do
        local CLUSTER_NS="$CLUSTER_NAME"
        local region
        if [[ "$CLUSTER_NAME" == "ocp-primary" ]]; then
            region="$HUB_REGION"
        else
            region="$SECONDARY_REGION"
        fi

        # The gateway SG is tagged with the cluster infra ID
        local infra_id
        infra_id=$(oc get clusterdeployment "$CLUSTER_NAME" -n "$CLUSTER_NS" \
            -o jsonpath='{.spec.clusterMetadata.infraID}' 2>/dev/null || true)
        [[ -z "$infra_id" ]] && { warn "Cannot get infraID for $CLUSTER_NAME, skipping SG fix"; continue; }

        local sg_id
        sg_id=$(aws ec2 describe-security-groups \
            --region "$region" \
            --filters "Name=tag:Name,Values=${infra_id}-submariner-gw-sg" \
            --query 'SecurityGroups[0].GroupId' \
            --output text 2>/dev/null || true)
        [[ -z "$sg_id" || "$sg_id" == "None" ]] && { warn "No submariner-gw-sg found for $CLUSTER_NAME, skipping"; continue; }

        for PORT in 4490 4800; do
            # Only add if not already present
            local existing
            existing=$(aws ec2 describe-security-groups \
                --region "$region" \
                --group-ids "$sg_id" \
                --query "SecurityGroups[0].IpPermissions[?FromPort==\`$PORT\`].FromPort" \
                --output text 2>/dev/null || true)
            if [[ -z "$existing" ]]; then
                aws ec2 authorize-security-group-ingress \
                    --region "$region" \
                    --group-id "$sg_id" \
                    --protocol udp \
                    --port "$PORT" \
                    --cidr 0.0.0.0/0 2>/dev/null \
                && log "  Opened UDP $PORT on $CLUSTER_NAME ($sg_id)" \
                || warn "  Failed to open UDP $PORT on $CLUSTER_NAME (may already exist)"
            else
                log "  UDP $PORT already open on $CLUSTER_NAME"
            fi
        done
    done
}

wait_for_convergence() {
    log "Waiting for full environment convergence..."
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

    log "Monitoring ArgoCD applications..."
    local tries=0
    while [[ $tries -lt 120 ]]; do
        local unhealthy
        unhealthy=$(oc get applications.argoproj.io -n ramendr-starter-kit-hub \
            -o custom-columns=':.status.sync.status,:.status.health.status' --no-headers 2>/dev/null \
            | grep -v "Synced.*Healthy" | grep -v "Synced.*Progressing" | wc -l | tr -d ' ')

        if [[ "$unhealthy" -eq 0 ]]; then
            log "All ArgoCD applications are Synced/Healthy!"
            break
        fi

        log "  $unhealthy apps still converging (attempt $tries/120)..."
        sleep 60
        tries=$((tries + 1))

        # Re-sync stuck apps periodically
        if [[ $((tries % 10)) -eq 0 ]]; then
            for app in regional-dr opp-policy; do
                oc patch applications.argoproj.io "$app" -n ramendr-starter-kit-hub --type merge \
                    -p '{"operation":{"initiatedBy":{"automated":true},"sync":{}}}' 2>/dev/null || true
            done
        fi
    done
}

show_status() {
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
    echo ""
    echo "============================================"
    echo "  RamenDR Starter Kit — Environment Status"
    echo "============================================"
    echo ""
    echo "--- Clusters ---"
    oc get managedclusters 2>&1 || echo "Cannot reach hub cluster"
    echo ""
    echo "--- ClusterDeployments ---"
    oc get clusterdeployments -A 2>&1
    echo ""
    echo "--- ArgoCD Applications ---"
    oc get applications.argoproj.io -n ramendr-starter-kit-hub \
        -o custom-columns='NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status' 2>&1
    echo ""
    echo "--- DR Status ---"
    oc get drpolicy 2>&1
    oc get drplacementcontrol -A 2>&1
    echo ""
    echo "--- VMs (on primary) ---"
    local primary_kc
    primary_kc=$(oc get secret -n ocp-primary -o name 2>/dev/null | grep admin-kubeconfig | head -1)
    if [[ -n "$primary_kc" ]]; then
        oc get vm -A --kubeconfig <(oc get "$primary_kc" -n ocp-primary -o jsonpath='{.data.kubeconfig}' | base64 -d) 2>&1
    else
        echo "Primary cluster kubeconfig not found"
    fi
    echo ""
    echo "--- Access ---"
    echo "Hub Console:  https://console-openshift-console.apps.hub.${BASE_DOMAIN}"
    echo "ArgoCD:       $(oc get route hub-gitops-server -n ramendr-starter-kit-hub -o jsonpath='https://{.spec.host}' 2>/dev/null)"
    echo "KUBECONFIG:   $HUB_INSTALL_DIR/auth/kubeconfig"
    echo ""
}

full_redeploy() {
    check_prerequisites
    cleanup_dns
    release_orphaned_eips
    destroy_hub
    cleanup_dns
    install_hub
    scale_hub_workers
    deploy_pattern
    wait_for_convergence
    fix_submariner_vxlan_sg
    show_status
    log "Full redeploy complete!"
}

case "${1:-}" in
    --destroy-only)
        check_prerequisites
        destroy_hub
        cleanup_dns
        release_orphaned_eips
        log "Environment destroyed."
        ;;
    --pattern-only)
        check_prerequisites
        scale_hub_workers
        deploy_pattern
        wait_for_convergence
        fix_submariner_vxlan_sg
        show_status
        ;;
    --status)
        show_status
        ;;
    --help|-h)
        echo "Usage: ./redeploy.sh [--destroy-only|--pattern-only|--status|--help]"
        echo ""
        echo "  (no args)        Full redeploy: destroy + install hub + deploy pattern"
        echo "  --destroy-only   Destroy all clusters and clean up AWS resources"
        echo "  --pattern-only   Deploy pattern on an existing hub cluster"
        echo "  --status         Show current environment status"
        echo ""
        echo "Environment variables:"
        echo "  HUB_INSTALL_DIR  Hub cluster install directory (default: ~/git/hub-cluster-install)"
        echo "  VALUES_SECRET    Path to values-secret.yaml (default: ~/values-secret.yaml)"
        echo "  HOSTED_ZONE_ID   Route53 hosted zone ID (default: Z01653801KMZNKX9NGW6G)"
        ;;
    *)
        full_redeploy
        ;;
esac
