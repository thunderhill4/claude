#!/usr/bin/env bash
# Installs MetalLB on cluster1 with a pool distinct from cluster2's.
#
# Deliberately NOT reusing 01-metallb/install-metallb.sh: that script derives an
# IP range then seds for IP_RANGE_PLACEHOLDER, which does not appear in
# 01-metallb/metallb-config.yaml (the pool is hardcoded to .211-.220). Running it
# against cluster1 would advertise cluster2's range on the shared L2 segment.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

require_cmd kubectl
require_ctx "$CTX1"

banner "Prereq 1/3 — MetalLB on cluster1 (pool 172.18.255.200-210)"

if kubectl --context "$CTX1" get ns metallb-system &>/dev/null; then
  ok "metallb-system namespace already present"
else
  info "Installing MetalLB ${METALLB_VERSION}…"
  run_cmd kubectl --context "$CTX1" apply -f \
    "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"
fi

info "Waiting for MetalLB controller…"
kubectl --context "$CTX1" wait --namespace metallb-system \
  --for=condition=ready pod --selector=app=metallb --timeout=180s

# Guard against the pool collision this script exists to prevent.
KIND_SUBNET=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Subnet}}' 2>/dev/null || echo "")
[[ "$KIND_SUBNET" == "172.18.0.0/16" ]] || warn "kind subnet is '${KIND_SUBNET}', expected 172.18.0.0/16 — pool may not be routable"

info "Applying cluster1 pool…"
run_cmd kubectl --context "$CTX1" apply -f "${ADV_ROOT}/00-prereqs/metallb-cluster1.yaml"

# Act 3's cluster2 east-west gateway needs .221, one past the end of cluster2's
# original .211-.220 pool. Widening is preferred over reusing .216, which the
# legacy 05-istio cross-cluster demo claims for its nginx proxy — sharing it
# would make the two demos mutually exclusive.
banner "Widening the cluster2 pool for Act 3 (.211-.225)"
if kubectl --context "$CTX2" get ipaddresspool kind-pool -n metallb-system &>/dev/null; then
  cur=$(kubectl --context "$CTX2" get ipaddresspool kind-pool -n metallb-system \
        -o jsonpath='{.spec.addresses[0]}')
  if [[ "$cur" == "172.18.255.211-172.18.255.225" ]]; then
    ok "cluster2 pool already ${cur}"
  else
    detail "current: ${cur}"
    run_cmd kubectl --context "$CTX2" patch ipaddresspool kind-pool -n metallb-system \
      --type=merge -p '{"spec":{"addresses":["172.18.255.211-172.18.255.225"]}}'
    ok "cluster2 pool widened to 172.18.255.211-172.18.255.225"
  fi
else
  warn "cluster2 has no 'kind-pool' IPAddressPool — run 01-metallb/install-metallb.sh first"
fi

echo ""
ok "MetalLB ready on cluster1"
detail "cluster1 pool: $(kubectl --context "$CTX1" get ipaddresspool cluster1-pool -n metallb-system -o jsonpath='{.spec.addresses[0]}')"
detail "cluster2 pool: $(kubectl --context "$CTX2" get ipaddresspool -n metallb-system -o jsonpath='{.items[0].spec.addresses[0]}' 2>/dev/null || echo 'n/a')"
