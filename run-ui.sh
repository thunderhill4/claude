#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UI_DIR="$SCRIPT_DIR/ui"

cleanup() {
    echo "Shutting down..."
    kill $BACKEND_PID $FRONTEND_PID 2>/dev/null
    wait $BACKEND_PID $FRONTEND_PID 2>/dev/null
    echo "Done."
}
trap cleanup EXIT INT TERM

# Start the Go backend
echo "Starting backend on :8080..."
cd "$UI_DIR/backend"
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
echo ""
echo "Press Ctrl+C to stop."

wait
