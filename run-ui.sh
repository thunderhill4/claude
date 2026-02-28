#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/ui"

# Ports for local port-forwards to kagent services
KAGENT_LOCAL_PORT="${KAGENT_LOCAL_PORT:-18080}"
CONTROLLER_LOCAL_PORT="${CONTROLLER_LOCAL_PORT:-18083}"

KAGENT_NS="${KAGENT_AGENT_NAMESPACE:-kagent}"
KAGENT_AGENT="${KAGENT_AGENT_NAME:-k8s-agent}"
TARGET_AGENT_LOCAL_PORT="${TARGET_AGENT_LOCAL_PORT:-18081}"

cleanup() {
    echo "Shutting down..."
    kill $BACKEND_PID $FRONTEND_PID $PF_AGENT_PID $PF_CTRL_PID $PF_TARGET_PID 2>/dev/null
    wait $BACKEND_PID $FRONTEND_PID $PF_AGENT_PID $PF_CTRL_PID $PF_TARGET_PID 2>/dev/null
    echo "Done."
}
trap cleanup EXIT INT TERM

# Port-forward kagent services so the local backend can reach them
echo "Setting up port-forwards to kagent in namespace '$KAGENT_NS'..."
kubectl port-forward -n "$KAGENT_NS" "svc/$KAGENT_AGENT" "${KAGENT_LOCAL_PORT}:8080" >/dev/null 2>&1 &
PF_AGENT_PID=$!
kubectl port-forward -n "$KAGENT_NS" svc/kagent-controller "${CONTROLLER_LOCAL_PORT}:8083" >/dev/null 2>&1 &
PF_CTRL_PID=$!

# Port-forward target-cluster-agent (if it exists)
if kubectl get svc target-cluster-agent -n "$KAGENT_NS" &>/dev/null; then
    echo "Setting up port-forward to target-cluster-agent on :${TARGET_AGENT_LOCAL_PORT}..."
    kubectl port-forward -n "$KAGENT_NS" svc/target-cluster-agent "${TARGET_AGENT_LOCAL_PORT}:8080" >/dev/null 2>&1 &
    PF_TARGET_PID=$!
else
    PF_TARGET_PID=""
fi
sleep 2

# Start the Go backend with URLs pointing to the local port-forwards
echo "Starting backend on :8080..."
cd "$UI_DIR/backend"
KAGENT_AGENT_URL="http://localhost:${KAGENT_LOCAL_PORT}/" \
KAGENT_CONTROLLER_URL="http://localhost:${CONTROLLER_LOCAL_PORT}/api/agents" \
KAGENT_AGENT_NAME="$KAGENT_AGENT" \
KAGENT_AGENT_NAMESPACE="$KAGENT_NS" \
KAGENT_AGENT_URL_TARGET_CLUSTER_AGENT="http://localhost:${TARGET_AGENT_LOCAL_PORT}/" \
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
echo "  kagent ($KAGENT_AGENT) forwarded from localhost:${KAGENT_LOCAL_PORT}"
echo ""
echo "Press Ctrl+C to stop."

wait
