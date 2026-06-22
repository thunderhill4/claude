#!/bin/bash
# Import Ubuntu base cloud-images as CDI DataVolumes in the default namespace.
#
# These are prerequisites for bake-golden-image.sh (source: ubuntu-noble-dv)
# and bake-golden-image-minimal.sh (source: ubuntu-minimal-noble-dv).
#
# Each import is gated on DV existence — re-running the script is a no-op
# once the DVs are Succeeded.
#
# Usage:
#   ./scripts/import-base-images.sh              # both
#   VARIANTS=noble ./scripts/import-base-images.sh
#   VARIANTS=minimal ./scripts/import-base-images.sh
set -euo pipefail

VARIANTS="${VARIANTS:-noble minimal}"

NOBLE_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
MINIMAL_URL="https://cloud-images.ubuntu.com/minimal/releases/noble/release/ubuntu-24.04-minimal-cloudimg-amd64.img"

apply_dv() {
  local name="$1" url="$2" size="$3"
  if kubectl -n default get dv "$name" >/dev/null 2>&1; then
    local phase
    phase=$(kubectl -n default get dv "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$phase" = "Succeeded" ]; then
      echo "==> $name already imported (Succeeded) — skipping"
      return 0
    fi
    echo "==> $name exists in phase '$phase' — leaving in place (delete manually to retry)"
    return 0
  fi

  echo "==> Creating DV $name from $url ($size)"
  kubectl apply -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${name}
  namespace: default
  annotations:
    cdi.kubevirt.io/storage.bind.immediate.requested: "true"
spec:
  source:
    http:
      url: ${url}
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: ${size}
EOF
}

wait_dv() {
  local name="$1"
  echo -n "==> Waiting for $name to import"
  local deadline=$(( $(date +%s) + 1800 ))   # 30 min
  while :; do
    local phase
    phase=$(kubectl -n default get dv "$name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    local progress
    progress=$(kubectl -n default get dv "$name" -o jsonpath='{.status.progress}' 2>/dev/null || echo "")
    printf "\r==> %s: %-12s %s            " "$name" "${phase:-Pending}" "${progress:-}"
    case "$phase" in
      Succeeded) echo; return 0 ;;
      Failed) echo; echo "ERROR: $name import failed" >&2; return 1 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo; echo "ERROR: $name import timed out after 30 minutes" >&2; return 1
    fi
    sleep 5
  done
}

for v in $VARIANTS; do
  case "$v" in
    noble)   apply_dv ubuntu-noble-dv         "$NOBLE_URL"   8Gi ;;
    minimal) apply_dv ubuntu-minimal-noble-dv "$MINIMAL_URL" 8Gi ;;
    *) echo "unknown variant: $v (expected noble|minimal)" >&2; exit 1 ;;
  esac
done

for v in $VARIANTS; do
  case "$v" in
    noble)   wait_dv ubuntu-noble-dv ;;
    minimal) wait_dv ubuntu-minimal-noble-dv ;;
  esac
done

echo "==> Done. DataVolumes ready in default namespace:"
kubectl -n default get dv
