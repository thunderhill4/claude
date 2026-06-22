#!/bin/bash
# Render 03-target-cluster/target-cluster.tmpl.yaml for CLI deploys.
#
# Mirrors the backend's strings.ReplaceAll pass in ui/backend/handlers/
# cluster_deploy.go. Writes the rendered manifest to stdout.
#
# Env vars:
#   PROFILE      lite | full                 (default: full)
#   IMAGE_VARIANT noble | minimal            (default: noble)
#   CLUSTER_NAME                              (default: target-cluster)
#   API_LB_IP                                 (default: 172.18.255.215)
#
# Usage:
#   PROFILE=lite IMAGE_VARIANT=minimal ./scripts/render-cluster.sh | kubectl apply -f -
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL="${SCRIPT_DIR}/../03-target-cluster/target-cluster.tmpl.yaml"

PROFILE="${PROFILE:-full}"
IMAGE_VARIANT="${IMAGE_VARIANT:-noble}"
CLUSTER_NAME="${CLUSTER_NAME:-target-cluster}"
API_LB_IP="${API_LB_IP:-172.18.255.215}"

case "$PROFILE" in
  lite) CP_CPU=2; CP_MEM=4Gi; WORKER_CPU=2; WORKER_MEM=4Gi ;;
  full) CP_CPU=4; CP_MEM=8Gi; WORKER_CPU=4; WORKER_MEM=6Gi ;;
  *) echo "unknown PROFILE: $PROFILE (expected lite|full)" >&2; exit 1 ;;
esac

case "$IMAGE_VARIANT" in
  noble)   IMAGE="172.18.0.2:5000/ubuntu-noble-k3s:preinit" ;;
  minimal) IMAGE="172.18.0.2:5000/ubuntu-minimal-k3s:preinit" ;;
  *) echo "unknown IMAGE_VARIANT: $IMAGE_VARIANT (expected noble|minimal)" >&2; exit 1 ;;
esac

sed \
  -e "s|{{CLUSTER_NAME}}|${CLUSTER_NAME}|g" \
  -e "s|{{IMAGE}}|${IMAGE}|g" \
  -e "s|{{API_LB_IP}}|${API_LB_IP}|g" \
  -e "s|{{CP_CPU}}|${CP_CPU}|g" \
  -e "s|{{CP_MEM}}|${CP_MEM}|g" \
  -e "s|{{WORKER_CPU}}|${WORKER_CPU}|g" \
  -e "s|{{WORKER_MEM}}|${WORKER_MEM}|g" \
  "$TMPL" | {
    rendered=$(cat)
    if grep -q '{{' <<<"$rendered"; then
      echo "error: unresolved placeholder in rendered manifest:" >&2
      grep -n '{{' <<<"$rendered" >&2
      exit 1
    fi
    printf '%s\n' "$rendered"
  }
