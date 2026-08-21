#!/usr/bin/env bash
# Installs Istio ${ISTIO_VERSION} in ambient mode on cluster1 and cluster2,
# multicluster-ready from the start (see istio-values-*.yaml for why).
#
# Prerequisite: gen-mesh-ca.sh must have run — istiod reads `cacerts` only at
# startup, so installing first would self-sign a per-cluster root and break Act 3.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_cmd kubectl
require_ctx "$CTX1"; require_ctx "$CTX2"
resolve_istioctl

banner "Install 2/2 — Istio ${ISTIO_VERSION} ambient on both clusters"

# Hard gate: without cacerts we would silently build Acts 1-2 on a mesh that
# cannot federate, and only discover it in Act 3.
for ctx in "$CTX1" "$CTX2"; do
  kubectl --context "$ctx" get secret cacerts -n istio-system &>/dev/null \
    || die "cacerts Secret missing in ${ctx}. Run 01-install/gen-mesh-ca.sh first."
done
ok "cacerts present in both clusters"

install_one() {
  local ctx="$1" cluster="$2" network="$3"
  info "Installing Istio on ${ctx} (network=${network})…"

  # ztunnel and istiod resolve the cluster's network from this label.
  run_cmd kubectl --context "$ctx" label namespace istio-system \
    "topology.istio.io/network=${network}" --overwrite

  run_cmd "$ISTIOCTL" install --context "$ctx" -y \
    -f "${ADV_ROOT}/01-install/istio-values-${cluster}.yaml"

  info "Waiting for control plane on ${ctx}…"
  kubectl --context "$ctx" wait --for=condition=Available --timeout=300s \
    -n istio-system deployment/istiod
  kubectl --context "$ctx" rollout status ds/ztunnel -n istio-system --timeout=300s
  ok "${ctx}: istiod + ztunnel ready"
}

install_one "$CTX1" cluster1 "$NET1"
install_one "$CTX2" cluster2 "$NET2"

banner "Verifying install"
# NOTE: `istioctl verify-install` was REMOVED in Istio 1.30 (it exits with
# "unknown command"). `istioctl analyze` is the supported replacement for
# validating a live installation.
for ctx in "$CTX1" "$CTX2"; do
  if "$ISTIOCTL" analyze --context "$ctx" -A >/dev/null 2>&1; then
    ok "${ctx}: istioctl analyze found no problems"
  else
    warn "${ctx}: istioctl analyze reported findings:"
    "$ISTIOCTL" analyze --context "$ctx" -A 2>&1 | head -6 | sed 's/^/      /'
  fi
  for d in istiod; do
    r=$(kubectl --context "$ctx" get deploy "$d" -n istio-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [[ "${r:-0}" -ge 1 ]] && ok "${ctx}: ${d} ready (${r})" || fail "${ctx}: ${d} not ready"
  done
  detail "${ctx} version: $("$ISTIOCTL" version --context "$ctx" --short 2>/dev/null | tr '\n' ' ')"
done

# Confirm istiod actually adopted the shared root rather than self-signing.
banner "Confirming istiod adopted the shared root CA"
# Collect fingerprints WITHOUT mixing in log output — `detail` writes to stdout,
# so redirecting the whole loop to a file would capture the log lines too.
_fps=()
for ctx in "$CTX1" "$CTX2"; do
  fp=$(kubectl --context "$ctx" get secret cacerts -n istio-system \
       -o jsonpath='{.data.root-cert\.pem}' 2>/dev/null | base64 -d 2>/dev/null \
       | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2)
  detail "${ctx} root SHA256: ${fp:-<unreadable>}"
  _fps+=("$fp")
done
if [[ -n "${_fps[0]}" && "${_fps[0]}" == "${_fps[1]}" ]]; then
  ok "Both clusters trust the same root — Act 3 can federate"
else
  warn "Root fingerprints differ or unreadable; Act 3 will fail until this is fixed"
fi

echo ""
ok "Istio ${ISTIO_VERSION} installed on cluster1 + cluster2"
detail "Next: 07-istio-advanced/act1-gateway/run.sh"
