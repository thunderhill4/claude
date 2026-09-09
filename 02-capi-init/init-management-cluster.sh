#!/usr/bin/env bash
set -euo pipefail

echo "==> Initializing CAPI management cluster..."
echo "    Infrastructure: KubeVirt (CAPK)"
echo "    Bootstrap:      k3s"
echo "    Control Plane:  k3s"

# Enable experimental features for ClusterResourceSet
export EXP_CLUSTER_RESOURCE_SET=true

clusterctl init \
  --infrastructure kubevirt \
  --bootstrap k3s \
  --control-plane k3s

echo "==> Waiting for CAPI core controller..."
kubectl wait --for=condition=available deployment/capi-controller-manager \
  -n capi-system --timeout=300s

echo "==> Waiting for CAPK infrastructure controller..."
kubectl wait --for=condition=available deployment/capk-controller-manager \
  -n capk-system --timeout=300s

echo "==> Waiting for k3s bootstrap controller..."
kubectl wait --for=condition=available deployment/capi-k3s-bootstrap-controller-manager \
  -n capi-k3s-bootstrap-system --timeout=300s 2>/dev/null || \
kubectl wait --for=condition=available deployment -l cluster.x-k8s.io/provider=bootstrap-k3s \
  --all-namespaces --timeout=300s 2>/dev/null || true

echo "==> Waiting for k3s control plane controller..."
kubectl wait --for=condition=available deployment/capi-k3s-control-plane-controller-manager \
  -n capi-k3s-control-plane-system --timeout=300s 2>/dev/null || \
kubectl wait --for=condition=available deployment -l cluster.x-k8s.io/provider=control-plane-k3s \
  --all-namespaces --timeout=300s 2>/dev/null || true

echo ""
echo "==> Management cluster initialized. Provider pods:"
kubectl get pods -n capi-system
kubectl get pods -n capk-system
kubectl get pods -A -l cluster.x-k8s.io/provider=bootstrap-k3s 2>/dev/null || true
kubectl get pods -A -l cluster.x-k8s.io/provider=control-plane-k3s 2>/dev/null || true

# Raise KubeVirt's support-container CPU limits (default 10m/15m throttles the
# containerDisk init container to ~8s per VM start). Measured: time-to-ready
# median 42.7s -> 34.5s. Idempotent; see scripts/configure-kubevirt-perf.sh.
bash "$(dirname "${BASH_SOURCE[0]}")/../scripts/configure-kubevirt-perf.sh" || true
