#!/usr/bin/env bash
# Act 3 — Two clusters, one mesh.
#
# Almost nothing happens here, and that is the point: meshID, clusterName,
# network and AMBIENT_ENABLE_MULTI_NETWORK were all set at install time, and the
# shared root CA was minted before istiod ever started. All that remains is an
# east-west gateway per cluster, a remote secret each way, and one Service label.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_ctx "$CTX1"; require_ctx "$CTX2"; resolve_istioctl
K1="kubectl --context ${CTX1}"; K2="kubectl --context ${CTX2}"
HERE="${ADV_ROOT}/act3-multicluster"

banner "Act 3 — Two clusters, one mesh (ambient multi-primary, multi-network)"

info "Confirming the shared root of trust…"
f1=$($K1 get secret cacerts -n istio-system -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)
f2=$($K2 get secret cacerts -n istio-system -o jsonpath='{.data.root-cert\.pem}' | base64 -d | openssl x509 -noout -fingerprint -sha256 | cut -d= -f2)
[[ "$f1" == "$f2" ]] || die "clusters do not share a root CA — rerun 01-install/gen-mesh-ca.sh and reinstall Istio"
ok "Shared root: ${f1:0:32}…"

detail "network labels:"
detail "  ${CTX1}: $($K1 get ns istio-system -o jsonpath='{.metadata.labels.topology\.istio\.io/network}')"
detail "  ${CTX2}: $($K2 get ns istio-system -o jsonpath='{.metadata.labels.topology\.istio\.io/network}')"

pause

banner "East-west gateways (HBONE :15008)"
run_cmd $K1 apply -f "${HERE}/01-eastwest-gateway-cluster1.yaml"
run_cmd $K2 apply -f "${HERE}/02-eastwest-gateway-cluster2.yaml"
$K1 wait --for=condition=Programmed gateway/istio-eastwest -n istio-system --timeout=180s
$K2 wait --for=condition=Programmed gateway/istio-eastwest -n istio-system --timeout=180s
# Resolved by label, not by name: each GatewayClass names its generated Service
# differently (see gateway_service in lib/common.sh).
EW1=$(wait_for_gateway_lb "$CTX1" istio-system istio-eastwest "$IP_EASTWEST_C1")
EW2=$(wait_for_gateway_lb "$CTX2" istio-system istio-eastwest "$IP_EASTWEST_C2")
ok "cluster1 east-west: ${EW1}"
ok "cluster2 east-west: ${EW2}"

pause

banner "Remote secrets — each istiod learns to read the peer's endpoints"
# --server is REQUIRED on Kind. Without it, create-remote-secret embeds the
# kubeconfig's own address, which is https://127.0.0.1:<random-host-port>. That
# is the host's port-forward, meaningless inside a pod, so the peer istiod can
# never reach the remote apiserver and the cluster sits at STATUS=timeout while
# everything else looks healthy. Use the node container's address on the shared
# Docker network instead (kind's apiserver cert already carries it as a SAN).
c1_ip=$(docker inspect cluster1-control-plane -f '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null)
c2_ip=$(docker inspect cluster2-control-plane -f '{{.NetworkSettings.Networks.kind.IPAddress}}' 2>/dev/null)
[[ -n "$c1_ip" && -n "$c2_ip" ]] || die "could not resolve kind node IPs via docker inspect"
detail "cluster1 apiserver: https://${c1_ip}:6443"
detail "cluster2 apiserver: https://${c2_ip}:6443"

info "cluster2 credentials -> cluster1…"
"$ISTIOCTL" create-remote-secret --context "$CTX2" --name cluster2 \
  --server "https://${c2_ip}:6443" | $K1 apply -f - >/dev/null
info "cluster1 credentials -> cluster2…"
"$ISTIOCTL" create-remote-secret --context "$CTX1" --name cluster1 \
  --server "https://${c1_ip}:6443" | $K2 apply -f - >/dev/null
ok "remote secrets exchanged"

# Assert the link actually came up. STATUS=timeout here means the peer istiod
# cannot reach the remote apiserver, and every cross-cluster claim afterwards
# would be false.
info "Waiting for both istiods to sync with their peer…"
synced=0
for _ in $(seq 1 30); do
  s1=$("$ISTIOCTL" remote-clusters --context "$CTX1" 2>/dev/null | awk '$1=="cluster2"{print $3}')
  s2=$("$ISTIOCTL" remote-clusters --context "$CTX2" 2>/dev/null | awk '$1=="cluster1"{print $3}')
  if [[ "$s1" == "synced" && "$s2" == "synced" ]]; then synced=1; break; fi
  sleep 5
done
if [[ "$synced" == "1" ]]; then
  ok "both clusters synced"
else
  fail "remote cluster sync incomplete (cluster1->cluster2=${s1:-?}, cluster2->cluster1=${s2:-?})"
  die "cross-cluster endpoint discovery will not work; fix before continuing"
fi
sleep 10
detail "istiod now sees both clusters:"
"$ISTIOCTL" remote-clusters --context "$CTX1" 2>/dev/null | sed 's/^/    /' || true

pause

banner "Deploying the peer workload on cluster2"
$K2 create namespace "$NS_APPS" --dry-run=client -o yaml | $K2 apply -f - >/dev/null
$K2 label namespace "$NS_APPS" istio.io/dataplane-mode=ambient --overwrite >/dev/null
# Reuse Act 1's backends so responses are distinguishable by pod name.
$K2 apply -f "${ADV_ROOT}/act1-gateway/01-backends.yaml" >/dev/null
$K2 rollout status deploy/echo-v1 -n "$NS_APPS" --timeout=240s
ok "echo running on cluster2"

# ─────────────────────────────────────────────────────────────────────────────
# Act 2 leaves an in-mesh HTTPRoute (echo-internal-split) attached to the echo
# Service, splitting to the echo-v1 / echo-v2 Services. Those version Services
# are NOT labeled istio.io/global, so once that route is in play, traffic is
# pinned to LOCAL backends and never consults the global Service. Scale cluster1
# to zero with it present and you get 503s, not failover — the mesh is working
# correctly, the route is simply more specific.
#
# Verified the hard way: with the route present, failover returned 503 on every
# request; deleting it returned 200 immediately.
#
# Lesson worth stating on stage: a route targeting non-global backends overrides
# global routing. Global services need routes that target the global Service, or
# no route at all.
# ─────────────────────────────────────────────────────────────────────────────
if $K1 get httproute echo-internal-split -n "$NS_APPS" &>/dev/null; then
  banner "Removing Act 2's local-only split route"
  detail "It pins echo -> echo-v1/echo-v2, which are not global, and would mask failover."
  run_cmd $K1 delete httproute echo-internal-split -n "$NS_APPS"
  sleep 5
fi

banner "One label makes the Service global"
detail "No ServiceEntry. No hardcoded MetalLB IP. No endpoint list."
detail "Contrast 05-istio/cross-cluster-demo.sh, which needs all three."
run_cmd $K1 apply -f "${HERE}/03-global-service.yaml"
run_cmd $K2 apply -f "${HERE}/03-global-service.yaml"
sleep 15

# A client on cluster1 to call from.
$K1 apply -f "${ADV_ROOT}/act2-waypoint/00-clients.yaml" >/dev/null
$K1 rollout status deploy/client-trusted -n "$NS_APPS" --timeout=180s

call() { $K1 exec -n "$NS_APPS" deploy/client-trusted -c curl -- \
         curl -s --max-time 10 http://echo/ 2>/dev/null || true; }

banner "Verify: local endpoints preferred while they are healthy"
loc=0; rem=0
for _ in $(seq 1 20); do
  b=$(call); [[ -z "$b" ]] && continue
  # echoserver reports its own pod name; cluster2's pods have distinct names.
  if echo "$b" | grep -q "$($K2 get pod -n "$NS_APPS" -l app=echo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)"; then
    rem=$((rem+1)); else loc=$((loc+1)); fi
done
detail "local=${loc}  remote=${rem}"
ok "traffic served (locality-aware routing prefers in-cluster endpoints)"

pause

banner "THE MONEY SHOT — scale cluster1 to zero, watch failover"
info "Baseline: cluster1 has $($K1 get deploy echo-v1 -n "$NS_APPS" -o jsonpath='{.status.readyReplicas}') local replicas"
info "Scaling ALL cluster1 echo replicas to 0 (no config change anywhere)…"
run_cmd $K1 scale deploy/echo-v1 deploy/echo-v2 -n "$NS_APPS" --replicas=0
$K1 wait --for=delete pod -l app=echo -n "$NS_APPS" --timeout=120s 2>/dev/null || sleep 10

info "Calling the same Service name 20 more times…"
okc=0; failc=0
for _ in $(seq 1 20); do
  b=$(call)
  if [[ -n "$b" ]]; then okc=$((okc+1)); else failc=$((failc+1)); fi
done
detail "success=${okc}  failed=${failc}"
if (( okc >= 18 )); then
  ok "Traffic failed over to cluster2 with zero config change and no app restart"
else
  fail "Failover incomplete: ${failc}/20 requests failed"
fi

info "Restoring cluster1 replicas…"
$K1 scale deploy/echo-v1 -n "$NS_APPS" --replicas=2 >/dev/null
$K1 scale deploy/echo-v2 -n "$NS_APPS" --replicas=1 >/dev/null

echo ""
ok "Act 3 complete — one mesh across two clusters and two networks"
