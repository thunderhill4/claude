#!/usr/bin/env bash
# Installs cert-manager on cluster1 (Act 1's TLS listener issues certs from it).
# cluster2 already has cert-manager from 06-sympozium/install-sympozium.sh, so
# this is idempotent there and skips.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_cmd kubectl
require_ctx "$CTX1"

banner "Prereq 3/3 — cert-manager ${CERT_MANAGER_VERSION} on cluster1"

if kubectl --context "$CTX1" get deployment cert-manager -n cert-manager &>/dev/null; then
  ok "cert-manager already installed on cluster1"
else
  info "Installing cert-manager…"
  run_cmd kubectl --context "$CTX1" apply -f \
    "https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"
  info "Waiting for cert-manager to become Available…"
  kubectl --context "$CTX1" wait --for=condition=Available --timeout=240s \
    -n cert-manager deployment/cert-manager \
    deployment/cert-manager-cainjector deployment/cert-manager-webhook
fi
ok "cert-manager ready on cluster1"
