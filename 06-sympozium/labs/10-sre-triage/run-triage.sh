#!/usr/bin/env bash
# Lab 10 — real agent work: SRE triage of a broken workload, scored.
#
# Deploys a deliberately-broken Deployment (image tag that doesn't exist →
# ImagePullBackOff), then asks the cluster2-agent (with the k8s-ops kubectl
# skill) to find it, diagnose the ROOT CAUSE from the cluster, and propose a
# fix — a genuinely useful multi-step task, not a toy prompt. Runs it N times
# and reports, per run: whether the agent nailed the root cause, how many
# kubectl calls it made, tokens, and latency — then an overall success rate.
#
# This is the "does the agent actually do useful work, and how reliably?"
# lab: the score is objective (did the diagnosis name the image-pull failure?),
# and the metrics show what that reliability costs.
#
# Usage: bash run-triage.sh [N]     (default N=3)
set -euo pipefail

CTX="${CLUSTER2_CONTEXT:-kind-cluster2}"
NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
AGENT="${LAB_AGENT:-cluster2-agent}"
MODEL="${LAB_MODEL:-qwen2.5:7b}"
BASEURL="http://host-ollama.sympozium-system.svc.cluster.local:11434/v1"
N="${1:-3}"
DIR="$(cd "$(dirname "$0")" && pwd)"

TASK="A workload in the sympozium-system namespace is unhealthy. Using kubectl \
(get pods, describe pod, get events — you have read-only access), find the \
broken workload, determine the ROOT CAUSE from the actual cluster state, and \
report: (1) the workload name, (2) the one-line root cause, (3) a one-line \
fix. Do not guess — inspect the cluster. Be concise."

echo "== Lab 10 SRE triage — $N run(s), model=$MODEL =="

echo "-- deploying broken workload --"
kubectl --context "$CTX" apply -f "$DIR/broken.yaml" >/dev/null
echo "   waiting for it to reach ImagePullBackOff/ErrImagePull..."
for _ in $(seq 1 30); do
  reason=$(kubectl --context "$CTX" get pods -n "$NS" -l app=lab-sre-broken \
    -o jsonpath='{.items[0].status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || true)
  case "$reason" in ImagePullBackOff|ErrImagePull) break;; esac
  sleep 3
done
echo "   broken workload state: ${reason:-<pending>}"
echo ""

pass=0
run_one() {
  local i=$1 name="lab-triage-$(date +%s)-$i"
  kubectl --context "$CTX" apply -f - >/dev/null <<YAML
apiVersion: sympozium.ai/v1alpha1
kind: AgentRun
metadata: { name: $name, namespace: $NS, labels: { lab: sre-triage } }
spec:
  agentRef: $AGENT
  agentId: primary
  sessionKey: $name
  mode: task
  cleanup: delete
  model: { provider: ollama, model: "$MODEL", baseURL: "$BASEURL", authSecretRef: llm-credentials }
  skills:
    - skillPackRef: k8s-ops
  task: |
    $TASK
YAML
  # wait for terminal phase
  local ph=""
  for _ in $(seq 1 40); do
    ph=$(kubectl --context "$CTX" get agentrun "$name" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    case "$ph" in Succeeded|Failed) break;; esac
    sleep 6
  done
  local result tools intok outtok dur
  result=$(kubectl --context "$CTX" get agentrun "$name" -n "$NS" -o jsonpath='{.status.result}' 2>/dev/null | tr -cd '[:print:]\n')
  tools=$(kubectl --context "$CTX" get agentrun "$name" -n "$NS" -o jsonpath='{.status.tokenUsage.toolCalls}' 2>/dev/null)
  intok=$(kubectl --context "$CTX" get agentrun "$name" -n "$NS" -o jsonpath='{.status.tokenUsage.inputTokens}' 2>/dev/null)
  outtok=$(kubectl --context "$CTX" get agentrun "$name" -n "$NS" -o jsonpath='{.status.tokenUsage.outputTokens}' 2>/dev/null)
  dur=$(kubectl --context "$CTX" get agentrun "$name" -n "$NS" -o jsonpath='{.status.tokenUsage.durationMs}' 2>/dev/null)

  # objective score: did it name both the broken workload and the image-pull cause?
  local hit_wl hit_cause verdict
  hit_wl=$(echo "$result" | grep -icE "lab-sre-broken" || true)
  hit_cause=$(echo "$result" | grep -icE "imagepull|image.*(pull|not found|does.?n.?t exist|invalid|missing)|pull.*(fail|back)|errimagepull" || true)
  if [ "$hit_wl" -ge 1 ] && [ "$hit_cause" -ge 1 ]; then verdict="PASS"; pass=$((pass+1)); else verdict="FAIL"; fi

  printf "run %d: %-4s phase=%-9s tools=%-2s in=%-5s out=%-4s dur=%ss\n" \
    "$i" "$verdict" "$ph" "${tools:-?}" "${intok:-?}" "${outtok:-?}" "$(( ${dur:-0} / 1000 ))"
  echo "  ↳ ${result:0:240}" | tr '\n' ' '; echo
}

echo "-- triage runs --"
for i in $(seq 1 "$N"); do run_one "$i"; done

echo ""
echo "═══ Result: $pass/$N runs correctly diagnosed the root cause ═══"
echo ""
echo "-- cleanup --"
kubectl --context "$CTX" delete -f "$DIR/broken.yaml" --ignore-not-found >/dev/null 2>&1 || true
kubectl --context "$CTX" delete agentrun -n "$NS" -l lab=sre-triage --ignore-not-found >/dev/null 2>&1 || true
echo "   done."
