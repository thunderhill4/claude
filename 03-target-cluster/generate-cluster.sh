#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Applying target cluster manifests..."
kubectl apply -f "${SCRIPT_DIR}/target-cluster.yaml"

echo ""
echo "==> Target cluster resources created. Monitoring provisioning..."
echo "    Use: kubectl get cluster,machine,kubevirtmachine -w"
echo "    Or run: ../04-verify/verify-cluster.sh"
