#!/usr/bin/env bash
# Lab 09 — AI agent metrics.
#
# Runs an IDENTICAL set of real, tool-using cluster-inspection tasks on TWO
# models (qwen2.5:7b and llama3.2) as one-shot AgentRuns, then aggregates each
# run's spec + status.tokenUsage into a real metrics report: tokens in/out,
# tool calls, latency, throughput (output tok/s), and success rate — with a
# side-by-side model comparison. The model is the only variable (same agentRef,
# same k8s-ops skill, same prompts), so the numbers are directly comparable.
#
# Metrics come straight from each AgentRun's `.status.tokenUsage`
# (inputTokens / outputTokens / totalTokens / toolCalls / durationMs) plus
# `.status.phase` — nothing is estimated by this script except tok/s (derived).
#
# Usage:   bash run-metrics.sh [--keep]
#   --keep : don't delete the batch's AgentRuns at the end (view them in the
#            dashboard; re-runnable — each run is uniquely named per batch).
set -euo pipefail

CTX="${CLUSTER2_CONTEXT:-kind-cluster2}"
NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
AGENT="${LAB_AGENT:-cluster2-agent}"
OLLAMA_ROOT="http://host-ollama.sympozium-system.svc.cluster.local:11434"
BASEURL="$OLLAMA_ROOT/v1"
BATCH="b$(date +%s)"
KEEP=0
[[ "${1:-}" == "--keep" ]] && KEEP=1

MODELS=("qwen2.5:7b" "llama3.2")

# task-id | prompt   (real, verifiable, exercise the k8s-ops kubectl sidecar)
TASKS=(
  "pods|Using kubectl, count how many pods are in the sympozium-system namespace. Reply with just the number and a one-sentence note."
  "nodes|Using kubectl, report how many nodes this cluster has and whether all of them are Ready."
  "vms|Using kubectl, run 'kubectl get virtualmachines -A' and report each VirtualMachine's name and status."
)

sanitize() { echo "$1" | tr ':.' '--' | tr -cd '[:alnum:]-'; }

echo "== Lab 09 metrics — batch $BATCH =="
echo "   models: ${MODELS[*]}"
echo "   tasks:  ${#TASKS[@]}   runs: $(( ${#MODELS[@]} * ${#TASKS[@]} ))"
echo ""

# --- warm both models so cold-start latency doesn't pollute the first run ----
echo "-- warming models (keeps latency comparable across runs) --"
for m in "${MODELS[@]}"; do
  kubectl --context "$CTX" run "warm-$(sanitize "$m")" -n "$NS" --rm -i --restart=Never \
    --timeout=90s --image=curlimages/curl:latest -- \
    -s --max-time 80 "$OLLAMA_ROOT/api/generate" \
    -d "{\"model\":\"$m\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"30m\"}" >/dev/null 2>&1 || true
  echo "   warmed $m"
done
echo ""

# --- create every run ---------------------------------------------------------
NAMES=()
for m in "${MODELS[@]}"; do
  for entry in "${TASKS[@]}"; do
    tid="${entry%%|*}"; prompt="${entry#*|}"
    name="lab-metrics-$BATCH-$(sanitize "$m")-$tid"
    NAMES+=("$name")
    kubectl --context "$CTX" apply -f - >/dev/null <<YAML
apiVersion: sympozium.ai/v1alpha1
kind: AgentRun
metadata:
  name: $name
  namespace: $NS
  labels:
    lab: metrics
    lab-batch: "$BATCH"
    lab-model: "$(sanitize "$m")"
    lab-task: "$tid"
spec:
  agentRef: $AGENT
  agentId: primary
  sessionKey: $name
  mode: task
  cleanup: delete
  model:
    provider: ollama
    model: "$m"
    baseURL: $BASEURL
    authSecretRef: llm-credentials
  skills:
    - skillPackRef: k8s-ops
  task: |
    $prompt
YAML
    echo "   created $name"
  done
done
echo ""

# --- wait for all to reach a terminal phase -----------------------------------
echo "-- waiting for runs to finish (up to 12 min) --"
deadline=$(( SECONDS + 720 ))
while (( SECONDS < deadline )); do
  pending=$(kubectl --context "$CTX" get agentruns -n "$NS" -l "lab-batch=$BATCH" \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null \
    | grep -vcE 'Succeeded|Failed' || true)
  total=${#NAMES[@]}
  done=$(( total - pending ))
  printf "\r   %d/%d complete" "$done" "$total"
  (( pending == 0 )) && break
  sleep 10
done
echo ""; echo ""

# --- aggregate + report -------------------------------------------------------
kubectl --context "$CTX" get agentruns -n "$NS" -l "lab-batch=$BATCH" -o json \
  | python3 "$(dirname "$0")/report.py"

# --- cleanup ------------------------------------------------------------------
if (( KEEP )); then
  echo ""
  echo "Kept batch $BATCH. View in dashboard (namespace sympozium-system), or clean up with:"
  echo "  kubectl delete agentruns -n $NS -l lab-batch=$BATCH"
else
  kubectl --context "$CTX" delete agentruns -n "$NS" -l "lab-batch=$BATCH" >/dev/null 2>&1 || true
  echo ""
  echo "Cleaned up batch $BATCH (re-run with --keep to inspect runs in the dashboard)."
fi
