#!/usr/bin/env bash
# Query the sympozium-llmfit-daemon: what does this node's hardware support,
# and which models fit? This is the same data behind the Sympozium
# dashboard's Gateway/hardware view (see the node-probe/llmfit fixes in
# CLAUDE.md's Common Pitfalls).
set -euo pipefail
NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
POD=$(kubectl get pod -n "$NS" -l app.kubernetes.io/component=llmfit-daemon -o jsonpath='{.items[0].metadata.name}')
PF_PORT=18787

kubectl port-forward -n "$NS" "pod/$POD" $PF_PORT:8787 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null' EXIT
sleep 2

echo "== Detected hardware =="
curl -s "localhost:$PF_PORT/api/v1/system" | jq '.system | {cpu_name, gpu_name, gpu_vram_gb, total_ram_gb, backend}'

echo ""
echo "== Top 5 models for coding =="
curl -s "localhost:$PF_PORT/api/v1/models/top?limit=5&use_case=coding" | jq .

echo ""
echo "== Good-fit models overall (top 10 by score) =="
curl -s "localhost:$PF_PORT/api/v1/models?limit=10&min_fit=good&sort=score" | jq .
