#!/usr/bin/env bash
# The sympozium-llmfit-daemon detects NVIDIA GPUs by shelling out to
# `nvidia-smi --query-gpu=memory.total,name ...`. Its container has no
# nvidia-smi (and the real one couldn't run anyway: no NVML lib, no
# /dev/nvidia* in the pod), so the NVIDIA entry ends up nameless with
# vram=null and llmfit picks the AMD iGPU (visible via sysfs
# mem_info_vram_total) as the primary GPU — the dashboard then shows
# "AMD GPU" instead of the actual NVIDIA card.
#
# Fix: capture the real answers from the host's nvidia-smi, write a tiny
# shim that replays them into the Kind node at /opt/llmfit-shim/, and
# mount that dir into the daemon at /usr/local/sbin (first in PATH;
# /usr/local/bin holds the llmfit binary itself, so don't shadow it).
#
# Shim values are static (captured at run time) — re-run after a GPU or
# driver change. The node-side file is lost if the node container is
# recreated; re-run via `make sympozium-fix-llmfit-gpu`.
#
# Usage: fix-llmfit-nvidia-smi.sh [node-container-name]

set -euo pipefail
NODE_CONTAINER="${1:-cluster2-control-plane}"
SYMPOZIUM_NS="${SYMPOZIUM_NAMESPACE:-sympozium-system}"

if ! command -v nvidia-smi &>/dev/null; then
    echo "WARNING: nvidia-smi not found on host — no NVIDIA GPU to report, skipping" >&2
    exit 0
fi
if ! docker inspect "$NODE_CONTAINER" &>/dev/null; then
    echo "WARNING: container '$NODE_CONTAINER' not found, skipping" >&2
    exit 0
fi

MEM_NAME=$(nvidia-smi --query-gpu=memory.total,name --format=csv,noheader,nounits)
ADDR_MEM_NAME=$(nvidia-smi --query-gpu=addressing_mode,memory.total,name --format=csv,noheader,nounits)
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader)
echo "Host GPU: $MEM_NAME"

docker exec -i "$NODE_CONTAINER" sh -c 'mkdir -p /opt/llmfit-shim && cat > /opt/llmfit-shim/nvidia-smi && chmod 755 /opt/llmfit-shim/nvidia-smi' <<EOF
#!/bin/sh
# Shim for llmfit-daemon: the real nvidia-smi cannot run in-container (no
# NVML lib, no /dev/nvidia* in the pod), so this replays answers captured
# from the actual host nvidia-smi by fix-llmfit-nvidia-smi.sh.
case "\$*" in
  *addressing_mode*) echo "$ADDR_MEM_NAME" ;;
  *memory.total*)    echo "$MEM_NAME" ;;
  *)                 echo "$GPU_NAME" ;;
esac
EOF
echo "Wrote /opt/llmfit-shim/nvidia-smi on $NODE_CONTAINER."

# Mount the shim dir into the daemon (idempotent: patch is a no-op if the
# volume/mount already exist with the same values).
if ! kubectl get ds sympozium-llmfit-daemon -n "$SYMPOZIUM_NS" &>/dev/null; then
    echo "WARNING: DaemonSet sympozium-llmfit-daemon not found in $SYMPOZIUM_NS, skipping patch" >&2
    exit 0
fi
kubectl patch ds sympozium-llmfit-daemon -n "$SYMPOZIUM_NS" --type=strategic -p '{
  "spec": {"template": {"spec": {
    "volumes": [{"name": "nvidia-smi-shim", "hostPath": {"path": "/opt/llmfit-shim", "type": "Directory"}}],
    "containers": [{"name": "llmfit-daemon",
      "volumeMounts": [{"name": "nvidia-smi-shim", "mountPath": "/usr/local/sbin", "readOnly": true}]}]
  }}}
}'
kubectl rollout status ds sympozium-llmfit-daemon -n "$SYMPOZIUM_NS" --timeout=120s
echo "llmfit-daemon patched; it should now report: $GPU_NAME"
