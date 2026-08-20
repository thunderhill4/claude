#!/usr/bin/env bash
# sympozium-node-probe (hostNetwork DaemonSet) checks 127.0.0.1:<port> for a
# locally-running LLM runtime (Ollama, vLLM, etc.) to populate the
# sympozium.ai/inference-* node annotations — surfaced as the "Gateway"/
# hardware info in the Sympozium dashboard. Ollama here runs on the actual
# Docker host, not inside the Kind node container, so loopback never reaches
# it (same reachability gap as the host-ollama Service shim works around for
# agent traffic — see 06-sympozium/host-ollama-service.yaml).
#
# This DNATs loopback:<port> to the docker bridge gateway (where Ollama
# listens) inside the Kind node's own network namespace via `docker exec` —
# an immediate one-shot fix. The rule is lost whenever the node container
# restarts (e.g. host reboot); node-probe-loopback-ds.yaml (in the kustomize
# bundle) re-asserts the same rule in a self-healing loop via hostPID +
# nsenter, so after `kubectl apply -k 06-sympozium/` this script is only
# needed when you want the rule applied *right now* without waiting for the
# DaemonSet's next tick. Idempotent: checks for the rule before adding it.
#
# Usage: fix-node-probe-loopback.sh [node-container-name]

set -euo pipefail
NODE_CONTAINER="${1:-cluster2-control-plane}"
PORT="${OLLAMA_PORT:-11434}"
HOST_IP="${DOCKER_BRIDGE_GATEWAY:-172.18.0.1}"

if ! docker inspect "$NODE_CONTAINER" &>/dev/null; then
    echo "WARNING: container '$NODE_CONTAINER' not found, skipping loopback redirect" >&2
    exit 0
fi

if docker exec "$NODE_CONTAINER" iptables -t nat -C OUTPUT -p tcp -o lo --dport "$PORT" \
    -j DNAT --to-destination "${HOST_IP}:${PORT}" 2>/dev/null; then
    echo "Loopback redirect 127.0.0.1:$PORT -> $HOST_IP:$PORT already present on $NODE_CONTAINER."
else
    docker exec "$NODE_CONTAINER" iptables -t nat -A OUTPUT -p tcp -o lo --dport "$PORT" \
        -j DNAT --to-destination "${HOST_IP}:${PORT}"
    echo "Added loopback redirect 127.0.0.1:$PORT -> $HOST_IP:$PORT on $NODE_CONTAINER."
fi
