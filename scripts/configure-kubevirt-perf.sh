#!/usr/bin/env bash
# configure-kubevirt-perf.sh — raise the CPU limits on KubeVirt's support containers.
#
# WHY (measured, not guessed):
# KubeVirt gives its per-VM support containers microscopic CPU limits by default:
#
#   volumesystemdisk  (the containerDisk)  cpu limit 10m   = 1%   of a core
#   guest-console-log (virt-tail)          cpu limit 15m   = 1.5% of a core
#
# 10m means the CFS quota grants ~1ms of CPU per 100ms period, so even
# `container-disk --no-op` needs dozens of periods just to dynamically link and
# fault in its pages. The launcher pod therefore spends ~8-9s getting to the
# point where qemu can start — on every VM, every time.
#
# This was isolated by elimination; each of these was measured and ruled out:
#   - image size          mounting the same 1.17GB image as an image volume and
#                         starting a container took +0.0s
#   - contention          a solo VMI took 9.0s, WORSE than 8.0s with two starting
#   - node CRI latency    a trivial 2-container pod started in 1.0s
#   - image volumes       fast (see above)
# The only remaining difference was the CPU limit — and the cost is deterministic
# (8.0s every run), which is the signature of a quota, not of load.
#
# EFFECT (3 clean runs each, same host/session):
#   containerDisk phase   8.0s -> 1.0s
#   pod -> qemu running  10.0s -> 4.0s
#   time-to-ready median 42.7s -> 34.5s   (spread 1.6s -> 0.5s)
#
# The limits below are a ceiling, not a reservation: these containers are short
# lived and idle after startup, so a 1-core ceiling costs nothing at steady state.
#
# Idempotent. Safe to re-run. Applies to pods created after it runs; existing VMs
# keep the limits they were created with.
set -euo pipefail

NS="${KUBEVIRT_NAMESPACE:-kubevirt}"
NAME="${KUBEVIRT_CR_NAME:-kubevirt}"
CPU_LIMIT="${SUPPORT_CONTAINER_CPU_LIMIT:-1}"

if ! kubectl get kubevirt "$NAME" -n "$NS" >/dev/null 2>&1; then
  echo "configure-kubevirt-perf: no KubeVirt CR '$NAME' in ns/$NS — skipping." >&2
  exit 0
fi

echo "==> Raising KubeVirt support-container CPU limits to ${CPU_LIMIT} (was 10m/15m)"

kubectl patch kubevirt "$NAME" -n "$NS" --type=merge -p "$(cat <<JSON
{"spec":{"configuration":{"supportContainerResources":[
  {"type":"container-disk",
   "resources":{"requests":{"cpu":"100m","memory":"40M"},"limits":{"cpu":"${CPU_LIMIT}","memory":"100M"}}},
  {"type":"guest-console-log",
   "resources":{"requests":{"cpu":"100m","memory":"60M"},"limits":{"cpu":"${CPU_LIMIT}","memory":"100M"}}}
]}}}
JSON
)" >/dev/null

echo "==> Now:"
kubectl get kubevirt "$NAME" -n "$NS" \
  -o jsonpath='{range .spec.configuration.supportContainerResources[*]}    {.type}{": cpu limit "}{.resources.limits.cpu}{"\n"}{end}'
echo "    (applies to launcher pods created from now on)"
