#!/usr/bin/env bash
# Installs Kubernetes Gateway API CRDs on both clusters.
#
# EXPERIMENTAL channel, not standard: Act 1 uses ListenerSet, which the
# standard channel does not ship. The experimental channel is a superset —
# it contains every standard-channel CRD plus the x- ones.
#
# Applied SERVER-SIDE. Client-side `kubectl apply` stores the full manifest in
# the last-applied-configuration annotation, and these CRDs exceed the 262144-byte
# annotation limit ("metadata.annotations: Too long"). Server-side apply keeps
# field ownership in the API server instead, so there is no annotation to blow.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_cmd kubectl
require_ctx "$CTX1"; require_ctx "$CTX2"

banner "Prereq 2/3 — Gateway API ${GATEWAY_API_VERSION} (experimental channel)"

CRD_URL="github.com/kubernetes-sigs/gateway-api/config/crd/experimental?ref=${GATEWAY_API_VERSION}"

for ctx in "$CTX1" "$CTX2"; do
  info "Applying Gateway API CRDs to ${ctx}…"
  kubectl kustomize "$CRD_URL" \
    | kubectl --context "$ctx" apply --server-side --force-conflicts -f - >/dev/null
  n=$(kubectl --context "$ctx" get crd -o name 2>/dev/null | grep -c 'gateway.networking.k8s.io' || true)
  ok "${ctx}: ${n} Gateway API CRDs"
  if kubectl --context "$ctx" get crd listenersets.gateway.networking.k8s.io &>/dev/null; then
    ok "${ctx}: ListenerSet present (Act 1 multi-tenant listeners)"
  else
    warn "${ctx}: ListenerSet missing — Act 1's ListenerSet step will not work"
  fi
done
