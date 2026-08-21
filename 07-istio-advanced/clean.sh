#!/usr/bin/env bash
# Tears down everything 07-istio-advanced created.
#
# Deliberately does NOT remove MetalLB, cert-manager, or anything belonging to
# 05-istio / 06-sympozium — those are shared or pre-existing.
set -uo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
resolve_istioctl

banner "Tearing down 07-istio-advanced"
for ctx in "$CTX1" "$CTX2"; do
  info "Cleaning ${ctx}…"
  kubectl --context "$ctx" delete ns "$NS_APPS" "$NS_INFRA" "$NS_ROGUE" ai-gateway \
    --ignore-not-found --timeout=120s 2>/dev/null
  kubectl --context "$ctx" delete gateway istio-eastwest -n istio-system --ignore-not-found 2>/dev/null
  kubectl --context "$ctx" delete secret -n istio-system -l istio/multiCluster=true --ignore-not-found 2>/dev/null
done

info "Uninstalling Istio (both clusters)…"
for ctx in "$CTX1" "$CTX2"; do
  "$ISTIOCTL" uninstall --context "$ctx" --purge -y 2>/dev/null || warn "${ctx}: uninstall reported problems"
  kubectl --context "$ctx" delete ns istio-system --ignore-not-found --timeout=180s 2>/dev/null
done

info "Removing generated CA…"
rm -rf "${CERT_DIR}"

ok "Teardown complete."
detail "Left in place: MetalLB, cert-manager, Gateway API CRDs, 05-istio, 06-sympozium."
