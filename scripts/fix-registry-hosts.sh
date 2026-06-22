#!/bin/bash
# Keep cluster2's containerd able to reach the local registry, regardless of
# the registry container's current IP on the kind network.
#
# Background: VMs / containerDisks reference the registry by a fixed alias
# (REGISTRY_ALIAS, default 172.18.0.2:5000). That alias is NOT a stable address
# — docker hands 172.18.0.2 to whichever container connected first (often a kind
# node, e.g. cluster1-control-plane). containerd resolves the alias via
# /etc/containerd/certs.d/<alias>/hosts.toml, which must point at the registry
# container's *actual* kind-network IP. Two things break that mapping:
#   1. The registry's IP drifts whenever containers reconnect to the network.
#   2. hosts.toml lives inside the node container's filesystem, so it is lost
#      if the node container is recreated.
# Either one leaves new VMs stuck in ImagePullBackOff.
#
# This script re-derives the registry's current IP and (re)writes hosts.toml on
# every cluster2 node. Idempotent — safe (and intended) to run before every
# deploy / pre-pull. containerd reads certs.d per pull, so no restart is needed.
#
# Usage:
#   ./scripts/fix-registry-hosts.sh
#   REGISTRY_CONTAINER=registry REGISTRY_ALIAS=172.18.0.2:5000 \
#     KIND_NETWORK=kind REGISTRY_PORT=5000 ./scripts/fix-registry-hosts.sh
set -euo pipefail

REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-registry}"
REGISTRY_ALIAS="${REGISTRY_ALIAS:-172.18.0.2:5000}"
KIND_NETWORK="${KIND_NETWORK:-kind}"
REGISTRY_PORT="${REGISTRY_PORT:-5000}"

# Registry's current IPv4 on the kind network.
REG_IP="$(docker inspect \
  -f "{{(index .NetworkSettings.Networks \"${KIND_NETWORK}\").IPAddress}}" \
  "${REGISTRY_CONTAINER}" 2>/dev/null || true)"
if [ -z "${REG_IP}" ]; then
  echo "ERROR: container '${REGISTRY_CONTAINER}' not found on docker network '${KIND_NETWORK}'." >&2
  echo "       Is the registry running and connected to the kind network?" >&2
  exit 1
fi

NODES="$(docker ps --filter "name=cluster2" --format '{{.Names}}')"
if [ -z "${NODES}" ]; then
  echo "ERROR: no cluster2 nodes found (docker ps --filter name=cluster2)." >&2
  exit 1
fi

echo "Registry '${REGISTRY_CONTAINER}' is at ${REG_IP}:${REGISTRY_PORT} on '${KIND_NETWORK}'."
echo "Mapping alias ${REGISTRY_ALIAS} -> http://${REG_IP}:${REGISTRY_PORT} on cluster2 node(s):"

CERTS_DIR="/etc/containerd/certs.d/${REGISTRY_ALIAS}"
for node in ${NODES}; do
  docker exec "${node}" mkdir -p "${CERTS_DIR}"
  docker exec -i "${node}" sh -c "cat > '${CERTS_DIR}/hosts.toml'" <<EOF
[host."http://${REG_IP}:${REGISTRY_PORT}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF
  echo "  ${node}: wrote ${CERTS_DIR}/hosts.toml"
done

echo "Done."
