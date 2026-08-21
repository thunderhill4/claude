#!/usr/bin/env bash
# Optional: installs the Gateway API Inference Extension CRDs for Act 4 tier 2.
# Separate from the act because it is experimental and not required for tier 1.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_ctx "$CTX1"

GIE_VERSION="${GIE_VERSION:-v1.0.1}"
banner "Gateway API Inference Extension ${GIE_VERSION} (experimental)"
warn "Tier 2 shows the routing API only — its endpoint picker schedules on"
warn "KV-cache/queue metrics that Ollama does not export. See README."

run_cmd kubectl --context "$CTX1" apply --server-side --force-conflicts -f \
  "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GIE_VERSION}/manifests.yaml"

for crd in inferencepools.inference.networking.k8s.io; do
  kubectl --context "$CTX1" get crd "$crd" &>/dev/null \
    && ok "$crd installed" || warn "$crd missing"
done
