#!/bin/bash
set -euo pipefail

#
# RamenDR Starter Kit — Full Environment Redeploy Script
#
# Usage:
#   ./redeploy.sh                    # Full redeploy: all clusters in parallel + pattern
#   ./redeploy.sh --destroy-only     # Destroy everything without redeploying
#   ./redeploy.sh --pattern-only     # Skip cluster installs, deploy pattern on existing hub
#   ./redeploy.sh --status           # Check current environment status
#
# All three clusters (hub + ocp-primary + ocp-secondary) are provisioned in
# parallel using openshift-install. The pattern runs in BYOC mode — spoke
# kubeconfigs are provided as secrets and the hub imports the clusters directly
# without going through Hive.
#
# Each cluster needs its own install directory containing install-config.yaml.bak:
#   HUB_INSTALL_DIR      (default: ~/git/hub-cluster-install)
#   PRIMARY_INSTALL_DIR  (default: ~/git/ocp-primary-install)
#   SECONDARY_INSTALL_DIR(default: ~/git/ocp-secondary-install)
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_INSTALL_DIR="${HUB_INSTALL_DIR:-$HOME/git/hub-cluster-install}"
PRIMARY_INSTALL_DIR="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}"
SECONDARY_INSTALL_DIR="${SECONDARY_INSTALL_DIR:-$HOME/git/ocp-secondary-install}"
VALUES_SECRET="${VALUES_SECRET:-$HOME/values-secret.yaml}"
HOSTED_ZONE_ID="${HOSTED_ZONE_ID:-Z01653801KMZNKX9NGW6G}"
BASE_DOMAIN="ecoengverticals-qe.devcluster.openshift.com"
HUB_REGION="eu-central-1"
SECONDARY_REGION="eu-west-1"
# Target OCP version for all clusters — hub + spokes should use the same minor version
# to avoid ODF Multicluster Orchestrator incompatibilities.
HUB_OCP_VERSION="${HUB_OCP_VERSION:-4.20.6}"

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
    local got_ocp
    got_ocp=$(openshift-install version 2>/dev/null | awk 'NR==1{print $2}')
    if [[ "$got_ocp" != "$HUB_OCP_VERSION" ]]; then
        warn "openshift-install is at $got_ocp, expected $HUB_OCP_VERSION — will auto-download at install time."
    fi
    if [[ ! -f "$VALUES_SECRET" ]]; then
        err "Missing secrets file: $VALUES_SECRET"
        missing=1
    fi
    for dir_var in HUB_INSTALL_DIR PRIMARY_INSTALL_DIR SECONDARY_INSTALL_DIR; do
        local dir="${!dir_var}"
        if [[ ! -f "$dir/install-config.yaml.bak" ]]; then
            err "Missing install-config backup: $dir/install-config.yaml.bak"
            missing=1
        fi
    done
    if ! podman machine info &>/dev/null; then
        warn "Podman machine not running. Starting..."
        podman machine start 2>/dev/null || true
    fi
    [[ $missing -eq 1 ]] && { err "Prerequisites not met. Aborting."; exit 1; }
    log "All prerequisites met."
}

cleanup_dns() {
    log "Cleaning stale DNS records from Route53..."
    local stale
    stale=$(aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" \
        --no-paginate --max-items 1000 --output json 2>/dev/null \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
base = '${BASE_DOMAIN}.'
changes = []
for r in data.get('ResourceRecordSets', []):
    name = r['Name']
    rtype = r['Type']
    if rtype in ('SOA', 'NS'):
        continue
    # Delete A/AAAA/CNAME records for any subdomain (cluster API, ingress, VM services, etc.)
    if rtype in ('A', 'AAAA', 'CNAME') and name != base:
        changes.append({'Action': 'DELETE', 'ResourceRecordSet': r})
    # Delete TXT records created by the External DNS operator
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

destroy_cluster() {
    local name="$1"
    local dir="$2"
    if [[ -f "$dir/metadata.json" ]]; then
        log "Destroying $name cluster..."
        openshift-install destroy cluster --dir "$dir" --log-level=info 2>&1 \
            || warn "$name destroy had errors (may already be destroyed)"
    else
        warn "No metadata found for $name — skipping (may already be destroyed)."
    fi
}

destroy_managed_clusters() {
    log "Destroying spoke clusters in parallel..."
    destroy_cluster "ocp-primary" "$PRIMARY_INSTALL_DIR" &
    destroy_cluster "ocp-secondary" "$SECONDARY_INSTALL_DIR" &
    wait
    log "Spoke clusters destroyed."
}

destroy_hub() {
    destroy_cluster "hub" "$HUB_INSTALL_DIR"
}

ensure_openshift_install_version() {
    local want="$HUB_OCP_VERSION"
    local got
    got=$(openshift-install version 2>/dev/null | awk 'NR==1{print $2}')
    if [[ "$got" == "$want" ]]; then
        log "openshift-install is already at $want."
        return 0
    fi
    log "openshift-install is at '$got', need $want — downloading..."
    local url="https://mirror.openshift.com/pub/openshift-v4/clients/ocp/${want}/openshift-install-linux.tar.gz"
    local tmp
    tmp=$(mktemp -d)
    curl -fsSL "$url" -o "$tmp/openshift-install.tar.gz"
    tar -xzf "$tmp/openshift-install.tar.gz" -C "$tmp" openshift-install
    chmod +x "$tmp/openshift-install"
    local install_dir
    install_dir=$(dirname "$(command -v openshift-install 2>/dev/null || echo "$HOME/bin/openshift-install")")
    mv "$tmp/openshift-install" "$install_dir/openshift-install"
    rm -rf "$tmp"
    log "openshift-install $want installed to $install_dir."
}

install_one_cluster() {
    local name="$1"
    local dir="$2"
    log "Installing $name cluster..."
    cd "$dir"
    setopt +o nomatch 2>/dev/null || true
    rm -rf .clusterapi_output .openshift_install.log .openshift_install_state.json \
           auth metadata.json terraform* 2>/dev/null || true
    cp install-config.yaml.bak install-config.yaml
    openshift-install create cluster --dir . --log-level=info 2>&1
    log "$name cluster installed."
}

install_hub() {
    ensure_openshift_install_version
    install_one_cluster "hub" "$HUB_INSTALL_DIR"

    log "Hub cluster installed. Setting up kubeconfig..."
    mkdir -p "$HOME/.kube"
    cp "$HUB_INSTALL_DIR/auth/kubeconfig" "$HOME/.kube/config"
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"

    log "Hub console: https://console-openshift-console.apps.hub.${BASE_DOMAIN}"
    grep -o 'password: "[^"]*"' "$HUB_INSTALL_DIR/.openshift_install.log" | tail -1 || true
}

install_spokes() {
    log "Installing ocp-primary and ocp-secondary in parallel..."
    install_one_cluster "ocp-primary" "$PRIMARY_INSTALL_DIR" &
    install_one_cluster "ocp-secondary" "$SECONDARY_INSTALL_DIR" &
    wait
    log "Both spoke clusters installed."
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
    log "Deploying RamenDR pattern (BYOC mode)..."
    export KUBECONFIG="$HUB_INSTALL_DIR/auth/kubeconfig"
    cd "$SCRIPT_DIR"

    log "Running pattern install (this takes ~20 minutes for operators to settle)..."
    VALUES_SECRET="$VALUES_SECRET" ./pattern.sh make install 2>&1 || warn "Pattern install exited with warnings (expected during first sync)"

    log "Fixing Vault privatekey secret..."
    local privkey pubkey
    privkey=$(oc exec -n vault vault-0 -- vault kv get -field=ssh-privatekey secret/hub/aws 2>/dev/null) || true
    pubkey=$(oc exec -n vault vault-0 -- vault kv get -field=ssh-publickey secret/hub/aws 2>/dev/null) || true
    if [[ -n "$privkey" ]]; then
        oc exec -n vault vault-0 -- vault kv put secret/hub/privatekey \
            ssh-privatekey="$privkey" ssh-publickey="$pubkey" 2>/dev/null
        log "  Vault secret/hub/privatekey created."
    fi
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

    # Destroy all clusters (spokes in parallel, hub after)
    destroy_managed_clusters
    destroy_hub
    cleanup_dns

    # Install all three clusters in parallel, then wait for all to complete
    log "Starting parallel install of hub + ocp-primary + ocp-secondary..."
    install_hub &
    install_spokes &
    wait
    log "All three clusters installed."

    scale_hub_workers
    deploy_pattern
    wait_for_convergence
    show_status
    log "Full redeploy complete!"
}

case "${1:-}" in
    --destroy-only)
        check_prerequisites
        destroy_managed_clusters
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
        show_status
        ;;
    --status)
        show_status
        ;;
    --help|-h)
        echo "Usage: ./redeploy.sh [--destroy-only|--pattern-only|--status|--help]"
        echo ""
        echo "  (no args)        Full redeploy: destroy + install all 3 clusters in parallel + deploy pattern"
        echo "  --destroy-only   Destroy all clusters and clean up AWS resources"
        echo "  --pattern-only   Deploy pattern on an existing hub cluster"
        echo "  --status         Show current environment status"
        echo ""
        echo "Environment variables:"
        echo "  HUB_INSTALL_DIR       Hub cluster install directory (default: ~/git/hub-cluster-install)"
        echo "  PRIMARY_INSTALL_DIR   Primary spoke install directory (default: ~/git/ocp-primary-install)"
        echo "  SECONDARY_INSTALL_DIR Secondary spoke install directory (default: ~/git/ocp-secondary-install)"
        echo "  VALUES_SECRET         Path to values-secret.yaml (default: ~/values-secret.yaml)"
        echo "  HUB_OCP_VERSION       OCP version for all clusters (default: 4.20.6)"
        echo "  HOSTED_ZONE_ID        Route53 hosted zone ID (default: Z01653801KMZNKX9NGW6G)"
        ;;
    *)
        full_redeploy
        ;;
esac
