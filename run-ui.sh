#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/ui"

SYMPOZIUM_NAMESPACE="${SYMPOZIUM_NAMESPACE:-sympozium-system}"
SYMPOZIUM_DEFAULT_AGENT="${SYMPOZIUM_DEFAULT_AGENT:-cluster2-agent}"

# MetalLB LoadBalancer IPs for Sympozium serving-mode Services (see sympozium-lb-setup.sh)
SYMPOZIUM_AGENT_URL="${SYMPOZIUM_AGENT_URL:-http://172.18.255.213:8080/}"
SYMPOZIUM_AGENT_URL_TARGET_CLUSTER_AGENT="${SYMPOZIUM_AGENT_URL_TARGET_CLUSTER_AGENT:-http://172.18.255.214:8080/}"
SYMPOZIUM_API_TOKEN="${SYMPOZIUM_API_TOKEN:-}"
if [[ -z "$SYMPOZIUM_API_TOKEN" ]]; then
    SYMPOZIUM_API_TOKEN="$(kubectl --context kind-cluster2 get secret -n "$SYMPOZIUM_NAMESPACE" "${SYMPOZIUM_DEFAULT_AGENT}-web-proxy-key" -o jsonpath='{.data.api-key}' 2>/dev/null | base64 -d || true)"
    if [[ -n "$SYMPOZIUM_API_TOKEN" ]]; then
        echo "Loaded SYMPOZIUM_API_TOKEN from secret ${SYMPOZIUM_DEFAULT_AGENT}-web-proxy-key"
    else
        echo "WARNING: could not fetch ${SYMPOZIUM_DEFAULT_AGENT}-web-proxy-key — agent calls will likely 401"
    fi
fi

SECURITY_AGENT_URL="${SECURITY_AGENT_URL:-http://localhost:8082}"

cleanup() {
    echo "Shutting down..."
    kill $BACKEND_PID $FRONTEND_PID ${SECURITY_PID:-} 2>/dev/null
    wait $BACKEND_PID $FRONTEND_PID ${SECURITY_PID:-} 2>/dev/null
    echo "Done."
}
trap cleanup EXIT INT TERM

echo "Starting backend on :8080..."
cd "$UI_DIR/backend"
SYMPOZIUM_NAMESPACE="$SYMPOZIUM_NAMESPACE" \
SYMPOZIUM_DEFAULT_AGENT="$SYMPOZIUM_DEFAULT_AGENT" \
SYMPOZIUM_AGENT_URL="$SYMPOZIUM_AGENT_URL" \
SYMPOZIUM_AGENT_URL_TARGET_CLUSTER_AGENT="$SYMPOZIUM_AGENT_URL_TARGET_CLUSTER_AGENT" \
SYMPOZIUM_API_TOKEN="$SYMPOZIUM_API_TOKEN" \
SECURITY_AGENT_URL="$SECURITY_AGENT_URL" \
CLAUDE_DIR="$SCRIPT_DIR" \
go run . &
BACKEND_PID=$!

if [[ "${RUN_SECURITY_AGENT:-}" == "1" ]]; then
  echo "Starting security agent on :8082..."
  cd "$SCRIPT_DIR/ui/security"
  OPA_POLICIES_DIR=./opa/policies \
  OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}" \
  OLLAMA_MODEL="${OLLAMA_MODEL:-gemma2:9b}" \
  go run . &
  SECURITY_PID=$!
  cd "$SCRIPT_DIR"
fi

echo "Starting frontend on :5173..."
cd "$UI_DIR/frontend"
npm run dev &
FRONTEND_PID=$!

echo ""
echo "UI is running:"
echo "  Frontend:              http://localhost:5173"
echo "  Backend:               http://localhost:8080"
echo "  Sympozium default:     ${SYMPOZIUM_AGENT_URL}  (${SYMPOZIUM_DEFAULT_AGENT})"
echo "  Sympozium target:      ${SYMPOZIUM_AGENT_URL_TARGET_CLUSTER_AGENT}  (target-cluster-agent)"
echo "  Security agent:        ${SECURITY_AGENT_URL}"
echo ""
echo "Press Ctrl+C to stop."

wait
