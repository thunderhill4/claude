#!/usr/bin/env bash
# Keep llama3.2 resident in Ollama so the first agent call doesn't race the
# ~28s CPU cold-start. Sends a 1-token completion with keep_alive=24h.
#
# Idempotent — safe to run on every demo invocation.

set -euo pipefail

OLLAMA_URL="${OLLAMA_URL:-http://172.18.0.1:11434}"
MODEL="${OLLAMA_MODEL:-llama3.2}"

echo "[warm] Checking Ollama at ${OLLAMA_URL}..."
if ! curl -sf --max-time 5 "${OLLAMA_URL}/api/tags" > /dev/null; then
    echo "[warm] ERROR: Ollama not reachable at ${OLLAMA_URL}" >&2
    echo "[warm] Hint: run 'ollama serve' on the host, or set OLLAMA_URL=..." >&2
    exit 1
fi

echo "[warm] Warming model '${MODEL}' with keep_alive=24h (first call may take ~30s)..."
# /api/generate honors keep_alive directly; one prompt token is enough to load.
resp=$(curl -sf --max-time 120 "${OLLAMA_URL}/api/generate" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${MODEL}\",\"prompt\":\"hi\",\"stream\":false,\"keep_alive\":\"24h\",\"options\":{\"num_predict\":1}}")

# Sanity check the response has a "done" field — Ollama always sets it.
if ! echo "$resp" | grep -q '"done"'; then
    echo "[warm] ERROR: unexpected response from Ollama:" >&2
    echo "$resp" >&2
    exit 1
fi

echo "[warm] OK — ${MODEL} is resident."
