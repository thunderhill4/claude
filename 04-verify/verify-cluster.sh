#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${1:-target-cluster}"
KUBECONFIG_FILE="/tmp/${CLUSTER_NAME}-kubeconfig"

echo "==> Checking cluster status..."
kubectl get cluster "${CLUSTER_NAME}"

echo ""
echo "==> Machine status:"
kubectl get machines -l cluster.x-k8s.io/cluster-name="${CLUSTER_NAME}"

echo ""
echo "==> KubeVirt machine status:"
kubectl get kubevirtmachine -l cluster.x-k8s.io/cluster-name="${CLUSTER_NAME}"

echo ""
echo "==> VirtualMachineInstances:"
kubectl get vmi -l cluster.x-k8s.io/cluster-name="${CLUSTER_NAME}" 2>/dev/null || \
  kubectl get vmi 2>/dev/null || echo "    No VMIs found yet"

echo ""
echo "==> Retrieving target cluster kubeconfig..."
if clusterctl get kubeconfig "${CLUSTER_NAME}" > "${KUBECONFIG_FILE}" 2>/dev/null; then
  echo "    Kubeconfig saved to: ${KUBECONFIG_FILE}"

  echo ""
  echo "==> Target cluster nodes:"
  kubectl --kubeconfig="${KUBECONFIG_FILE}" get nodes -o wide 2>/dev/null || \
    echo "    Cannot reach target cluster API server yet"

  echo ""
  echo "==> Target cluster pods:"
  kubectl --kubeconfig="${KUBECONFIG_FILE}" get pods -A 2>/dev/null || \
    echo "    Cannot reach target cluster API server yet"
else
  echo "    Kubeconfig not available yet (control plane may still be provisioning)"
fi

echo ""
echo "==> Done. If the cluster is still provisioning, re-run this script later."
