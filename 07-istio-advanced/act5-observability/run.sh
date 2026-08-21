#!/usr/bin/env bash
# Act 5 — Observability as the stage.
#
# Scoped deliberately: Kiali + Prometheus on cluster1 only. The host has limited
# headroom (cluster2 already carries KubeVirt VMs + Sympozium), and a second
# Prometheus buys nothing for the demo. Grafana is NOT installed here — cluster2
# already runs one.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_ctx "$CTX1"

ADDON_BASE="https://raw.githubusercontent.com/istio/istio/release-${ISTIO_VERSION%.*}/samples/addons"

banner "Act 5 — Observability (Kiali + Prometheus on cluster1)"

info "Installing Prometheus…"
run_cmd kubectl --context "$CTX1" apply -f "${ADDON_BASE}/prometheus.yaml"

info "Installing Kiali…"
run_cmd kubectl --context "$CTX1" apply -f "${ADDON_BASE}/kiali.yaml"

info "Waiting for addons…"
kubectl --context "$CTX1" rollout status deploy/prometheus -n istio-system --timeout=300s
kubectl --context "$CTX1" rollout status deploy/kiali -n istio-system --timeout=300s

info "Exposing Kiali on ${IP_KIALI}…"
kubectl --context "$CTX1" patch svc kiali -n istio-system --type=merge -p "{
  \"metadata\": {\"annotations\": {\"metallb.io/loadBalancerIPs\": \"${IP_KIALI}\"}},
  \"spec\": {\"type\": \"LoadBalancer\"}
}" >/dev/null
ip=$(wait_for_lb "$CTX1" istio-system kiali "$IP_KIALI")
ok "Kiali: http://${ip}:20001"

banner "Verifying telemetry is actually flowing"
# Generate traffic so the graph is non-empty, then assert Prometheus has metrics.
# A Kiali screenshot is not evidence; the metric count is.
if kubectl --context "$CTX1" get deploy client-trusted -n "$NS_APPS" &>/dev/null; then
  info "Generating traffic…"
  kubectl --context "$CTX1" exec -n "$NS_APPS" deploy/client-trusted -- \
    sh -c 'for i in $(seq 1 30); do curl -s -o /dev/null http://echo/ || true; done' 2>/dev/null || true
fi

info "Querying Prometheus for istio_requests_total (retries: scrape interval)…"
count=$(prom_count "$CTX1" 'count(istio_requests_total)' 12)
if [[ -n "$count" ]]; then
  ok "Prometheus has istio_requests_total series (count=${count})"
else
  warn "No istio_requests_total series yet — send traffic through the mesh, then re-check"
fi

echo ""
detail "Kiali graph:  http://${ip}:20001  (Traffic Graph -> namespace ${NS_APPS})"
detail "Ambient view shows ztunnel (L4) and waypoint (L7) as separate hops."
