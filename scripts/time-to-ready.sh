#!/usr/bin/env bash
# time-to-ready.sh — measure target-cluster boot time.
#
# Applies a target-cluster manifest, then polls the target kubeconfig until
# all expected nodes report Ready. Prints elapsed seconds.
#
# Usage:
#   ./scripts/time-to-ready.sh [<manifest>] [<expected-node-count>]
#
# Defaults: 03-target-cluster/target-cluster-preinit-test.yaml, 2 nodes.
#
# Requires: kubectl, clusterctl. The target kubeconfig is fetched via
# `clusterctl get kubeconfig target-cluster`.
set -euo pipefail

MANIFEST="${1:-03-target-cluster/target-cluster-preinit-test.yaml}"
EXPECTED_NODES="${2:-2}"
CLUSTER_NAME="${CLUSTER_NAME:-target-cluster}"
TIMEOUT="${TIMEOUT:-300}"
KUBECONFIG_OUT="$(mktemp)"

trap 'rm -f "$KUBECONFIG_OUT"' EXIT

if [ ! -f "$MANIFEST" ]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  exit 1
fi

echo "==> Applying $MANIFEST"
START_NS=$(date +%s%N)
kubectl apply -f "$MANIFEST"

echo "==> Waiting for target kubeconfig (cluster: $CLUSTER_NAME)..."
for i in $(seq 1 60); do
  if clusterctl get kubeconfig "$CLUSTER_NAME" >"$KUBECONFIG_OUT" 2>/dev/null && \
     [ -s "$KUBECONFIG_OUT" ]; then
    break
  fi
  sleep 2
done
if [ ! -s "$KUBECONFIG_OUT" ]; then
  echo "ERROR: kubeconfig never appeared." >&2
  exit 1
fi

echo "==> Polling target nodes (need $EXPECTED_NODES Ready)..."
ELAPSED=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
  READY=$(KUBECONFIG="$KUBECONFIG_OUT" kubectl get nodes \
    -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
    2>/dev/null | grep -c '^True$' || true)
  printf "\r    Ready nodes: %d/%d  [%ds]" "$READY" "$EXPECTED_NODES" "$ELAPSED"
  if [ "$READY" -ge "$EXPECTED_NODES" ]; then
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done
echo ""

END_NS=$(date +%s%N)
ELAPSED_MS=$(( (END_NS - START_NS) / 1000000 ))

if [ "$READY" -lt "$EXPECTED_NODES" ]; then
  echo "TIMEOUT after ${TIMEOUT}s — only $READY/$EXPECTED_NODES nodes Ready" >&2
  exit 1
fi

printf "RESULT: %d.%03ds (%d nodes Ready)\n" \
  "$((ELAPSED_MS / 1000))" "$((ELAPSED_MS % 1000))" "$EXPECTED_NODES"
