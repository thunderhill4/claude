#!/usr/bin/env bash
#
# bake-golden-image.sh — Bake the Ubuntu Noble general-purpose k3s image.
#
# Thin wrapper around bake-common.sh. All baking logic lives there; this
# script only sets the Noble-specific defaults. Override any env var to
# produce a custom variant without touching bake-common.sh.
#
# See bake-common.sh for the list of overridable env vars.
set -euo pipefail

DV_SOURCE="${DV_SOURCE:-ubuntu-noble-dv}"
DV_TARGET="${DV_TARGET:-ubuntu-noble-k3s-preinit}"
VM_NAME="${VM_NAME:-ubuntu-bake-vm-preinit}"
PVC_SIZE="${PVC_SIZE:-20Gi}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
TARGET_IMAGE="${TARGET_IMAGE:-localhost:5000/ubuntu-noble-k3s:preinit}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DV_SOURCE DV_TARGET VM_NAME PVC_SIZE EXTRA_PACKAGES TARGET_IMAGE
# shellcheck source=bake-common.sh
source "${SCRIPT_DIR}/bake-common.sh"
