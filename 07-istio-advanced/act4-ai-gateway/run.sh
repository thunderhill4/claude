#!/usr/bin/env bash
# Act 4 — AI gateway (Istio 1.30's headline feature).
#
# Two tiers on purpose. Tier 1 (agentgateway as a Gateway API data plane) is the
# act. Tier 2 (Gateway API Inference Extension) is genuinely experimental and is
# allowed to fail without taking the demo down.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"
require_ctx "$CTX1"
K="kubectl --context ${CTX1}"
HERE="${ADV_ROOT}/act4-ai-gateway"

banner "Act 4 — AI Gateway: agentgateway + host Ollama"

info "Checking the istio-agentgateway GatewayClass exists…"
if $K get gatewayclass istio-agentgateway &>/dev/null; then
  ok "GatewayClass istio-agentgateway present (PILOT_ENABLE_AGENTGATEWAY took effect)"
else
  fail "GatewayClass istio-agentgateway missing."
  detail "istiod needs PILOT_ENABLE_AGENTGATEWAY=true — set in"
  detail "01-install/istio-values-cluster1.yaml. Re-run 01-install/install-istio.sh."
  exit 1
fi

info "Host Ollama shim Service…"
run_cmd $K apply -f "${HERE}/00-host-ollama.yaml"
$K label namespace ai-gateway istio.io/dataplane-mode=ambient --overwrite >/dev/null

# Prove the backend is actually reachable before blaming the gateway later.
info "Confirming host Ollama answers from inside the cluster…"
models=$($K run ollama-probe -n ai-gateway --rm -i --restart=Never --quiet \
  --image=curlimages/curl:8.11.1 --command -- \
  curl -s --max-time 15 http://host-ollama.ai-gateway.svc.cluster.local:11434/api/tags 2>/dev/null || true)
if echo "$models" | grep -q '"name"'; then
  n=$(echo "$models" | grep -o '"name":"[^"]*"' | wc -l)
  ok "host Ollama reachable — ${n} models"
  echo "$models" | grep -o '"name":"[^"]*"' | head -4 | sed 's/^/      /'
else
  warn "host Ollama not reachable from cluster1 — check it is listening on 172.18.0.1:11434"
fi

pause

banner "The agentgateway — same Gateway API object, different proxy"
detail "gatewayClassName: istio-agentgateway swaps Envoy for agentgateway,"
detail "a proxy built for AI/agent protocols rather than general HTTP."
run_cmd $K apply -f "${HERE}/01-agentgateway.yaml"
$K wait --for=condition=Programmed gateway/ai-edge -n ai-gateway --timeout=180s || \
  warn "Gateway not Programmed — agentgateway is experimental in 1.30"

AI_IP=$(wait_for_gateway_lb "$CTX1" ai-gateway ai-edge "$IP_ACT4_AGENTGW" || true)
if [[ -z "$AI_IP" ]]; then
  warn "no LoadBalancer IP; the generated Service may be named differently:"
  $K get svc -n ai-gateway | sed 's/^/    /'
else
  ok "AI gateway address: ${AI_IP}"

  banner "Verify: model traffic through the mesh"
  tags=$(curl -s --max-time 30 "http://${AI_IP}/api/tags" 2>/dev/null || true)
  if echo "$tags" | grep -q '"name"'; then
    ok "GET /api/tags through the gateway returned the model list"
  else
    warn "no model list via the gateway (got: ${tags:0:120})"
  fi

  info "OpenAI-compatible completion through the gateway (may take ~30s cold)…"
  MODEL="${ACT4_MODEL:-qwen3.5:4b}"
  resp=$(curl -s --max-time 300 "http://${AI_IP}/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: ok\"}],\"stream\":false}" 2>/dev/null || true)
  content=$(echo "$resp" | sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -1)
  if [[ -n "$content" ]]; then
    ok "completion via the mesh: \"${content}\""
    detail "Model traffic now carries mesh policy + telemetry, same as any service."
  else
    warn "no completion (model '${MODEL}' may not be pulled). Response: ${resp:0:160}"
  fi
fi

pause

banner "Tier 2 (experimental) — Gateway API Inference Extension"
cat <<'NOTE'
    An InferencePool groups model servers; an InferenceObjective describes the
    serving goal. Istio routes to the pool via an Endpoint Picker (EPP) that
    schedules on model-server metrics.

    HONEST LIMITATION, worth saying out loud on stage:
      the EPP schedules on KV-cache utilization and queue depth, which vLLM and
      Triton export and Ollama does NOT. What follows demonstrates the routing
      API surface, not genuine load-aware scheduling. Real load-aware routing
      needs vLLM, which does not fit alongside everything else on this host.
NOTE
if $K get crd inferencepools.inference.networking.k8s.io &>/dev/null; then
  ok "InferencePool CRD present"
  $K get inferencepool -A 2>/dev/null | sed 's/^/    /' || true
else
  warn "Inference Extension CRDs not installed — tier 2 skipped."
  detail "Install with:"
  detail "  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v1.0.1/manifests.yaml"
fi

echo ""
ok "Act 4 complete"
