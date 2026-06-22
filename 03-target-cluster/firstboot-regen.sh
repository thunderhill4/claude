#!/bin/bash
# k3s first-boot identity regeneration.
#
# Runs as ExecStartPre of k3s.service on a VM booted from a pre-initialized
# golden image (the one produced by bake-common.sh). Issues a fresh etcd
# cluster identity via `k3s server --cluster-reset` while keeping all kube
# state (CRDs, RBAC, system charts, etc.).
#
# Idempotent: short-circuits on a sentinel file. Runs at most once per VM.
#
# Precondition (satisfied by CAPI preK3sCommands in target-cluster.tmpl.yaml):
#   - /var/lib/rancher/k3s/server/token from the bake-time warm-up run has
#     been removed, so `--cluster-reset` picks up the per-cluster token that
#     CAPI wrote to /etc/rancher/k3s/config.yaml. Otherwise CP would use the
#     bake-time token and workers — which CAPI gave a different token — would
#     fail to join.
#
# NOTE: this file is the canonical source. The same content is embedded inline
# in bake-common.sh (Step 6b) so the bake VM can write it into the image
# without an external file dependency. Keep both in sync.
set -euo pipefail

SENTINEL="/var/lib/rancher/k3s/.firstboot-done"

log() { echo "[firstboot-regen] $*"; }

if [ -f "$SENTINEL" ]; then
  log "Sentinel present — already regenerated. Skipping."
  exit 0
fi

log "Running k3s server --cluster-reset (preserves kube state, fresh etcd identity)..."
if ! /usr/local/bin/k3s server --cluster-reset >/var/log/k3s-firstboot-reset.log 2>&1; then
  log "FATAL: k3s --cluster-reset failed. Tail of log:"
  tail -50 /var/log/k3s-firstboot-reset.log >&2 || true
  exit 1
fi

NODE_PASSWD="/var/lib/rancher/k3s/server/cred/node-passwd"
if [ -f "$NODE_PASSWD" ]; then
  log "Clearing stale node-passwd entries (bake-time hostname)."
  : > "$NODE_PASSWD"
fi

# k3s regenerates kubeconfig on next start with the new node identity.
rm -f /etc/rancher/k3s/k3s.yaml

mkdir -p "$(dirname "$SENTINEL")"
touch "$SENTINEL"
log "Done."
