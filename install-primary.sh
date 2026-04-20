#!/bin/bash
# One-shot script to install ocp-primary after the redeploy script has
# already started hub and ocp-secondary. Run this in a separate terminal.
set -euo pipefail
PRIMARY_DIR="${PRIMARY_INSTALL_DIR:-$HOME/git/ocp-primary-install}"
rm -rf "$PRIMARY_DIR/.clusterapi_output" "$PRIMARY_DIR/.openshift_install.log" \
       "$PRIMARY_DIR/.openshift_install_state.json" "$PRIMARY_DIR/auth" \
       "$PRIMARY_DIR/metadata.json" 2>/dev/null || true
cp "$PRIMARY_DIR/install-config.yaml.bak" "$PRIMARY_DIR/install-config.yaml"
exec openshift-install create cluster --dir "$PRIMARY_DIR" --log-level=info
