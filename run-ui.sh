#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/ui"

KAGENT_NS="${KAGENT_AGENT_NAMESPACE:-kagent}"
KAGENT_AGENT="${KAGENT_AGENT_NAME:-k8s-agent}"

# MetalLB LoadBalancer IPs for kagent services (see kagent-lb-setup.sh)
KAGENT_AGENT_URL="${KAGENT_AGENT_URL:-http://172.18.255.212/}"
KAGENT_CONTROLLER_URL="${KAGENT_CONTROLLER_URL:-http://172.18.255.213:8083/api/agents}"
KAGENT_AGENT_URL_TARGET_CLUSTER_AGENT="${KAGENT_AGENT_URL_TARGET_CLUSTER_AGENT:-http://172.18.255.214/}"

cleanup() {
    echo "Shutting down..."
    kill $BACKEND_PID $FRONTEND_PID 2>/dev/null
    wait $BACKEND_PID $FRONTEND_PID 2>/dev/null
    echo "Done."
}
trap cleanup EXIT INT TERM

# Start the Go backend with URLs pointing to kagent LoadBalancer IPs
echo "Starting backend on :8080..."
cd "$UI_DIR/backend"
KAGENT_AGENT_URL="$KAGENT_AGENT_URL" \
KAGENT_CONTROLLER_URL="$KAGENT_CONTROLLER_URL" \
KAGENT_AGENT_NAME="$KAGENT_AGENT" \
KAGENT_AGENT_NAMESPACE="$KAGENT_NS" \
KAGENT_AGENT_URL_TARGET_CLUSTER_AGENT="$KAGENT_AGENT_URL_TARGET_CLUSTER_AGENT" \
CLAUDE_DIR="$SCRIPT_DIR" \
go run . &
BACKEND_PID=$!

# Start the Vite frontend dev server
echo "Starting frontend on :5173..."
cd "$UI_DIR/frontend"
npm run dev &
FRONTEND_PID=$!

echo ""
echo "UI is running:"
echo "  Frontend: http://localhost:5173"
echo "  Backend:  http://localhost:8080"
echo "  kagent ($KAGENT_AGENT): ${KAGENT_AGENT_URL}"
echo "  kagent controller:      ${KAGENT_CONTROLLER_URL}"
echo ""
echo "Press Ctrl+C to stop."

wait
