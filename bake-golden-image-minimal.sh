#!/usr/bin/env bash
#
# bake-golden-image-minimal.sh — Bake the Ubuntu Minimal lean k3s image.
#
# Ubuntu Minimal is ~60% smaller than Noble server but ships without several
# k3s hard deps. We install them via cloud-init `packages:` before bake.sh
# runs. Keeps systemd + cloud-init so bake-common.sh is unchanged.
#
# See bake-common.sh for the list of overridable env vars.
set -euo pipefail

DV_SOURCE="${DV_SOURCE:-ubuntu-minimal-noble-dv}"
DV_TARGET="${DV_TARGET:-ubuntu-minimal-k3s-preinit}"
VM_NAME="${VM_NAME:-ubuntu-minimal-bake-vm-preinit}"
PVC_SIZE="${PVC_SIZE:-15Gi}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-qemu-guest-agent curl ca-certificates iptables conntrack}"
TARGET_IMAGE="${TARGET_IMAGE:-localhost:5000/ubuntu-minimal-k3s:preinit}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DV_SOURCE DV_TARGET VM_NAME PVC_SIZE EXTRA_PACKAGES TARGET_IMAGE
# shellcheck source=bake-common.sh
source "${SCRIPT_DIR}/bake-common.sh"
