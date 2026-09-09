#!/usr/bin/env bash
# phase-timings.sh — per-phase breakdown of target-cluster time-to-ready.
#
# scripts/time-to-ready.sh prints ONE aggregate number, which is why two
# optimisation dead ends (:preinit, :warm) each cost a full bake cycle to
# disprove. This script attributes the wall clock to the phases that make it up,
# so a candidate change can be judged on the phase it claims to touch.
#
# Everything is collected READ-ONLY and WITHOUT SSH into the guests (virtctl's
# subresource API is unreliable here). Sources:
#   - CAPI/CAPK object creationTimestamps    → controller chain
#   - VMI status.phaseTransitionTimestamps   → schedule → Running
#   - virt-launcher container startedAt      → containerDisk + qemu start
#   - guest serial console (kubectl logs -c guest-console-log)
#                                            → kernel, initramfs, systemd,
#                                              cloud-init, k3s start/ready
#   - target-cluster node Ready transitions  → the metric itself
#   - a host-side probe loop                 → first TCP accept / first 200 on
#                                              https://<VIP>:6443/readyz
#
# Guest uptime stamps are anchored to wall clock using cloud-init's own log
# lines, which carry BOTH an absolute date and the uptime:
#   "running 'init' at Wed, 09 Sep 2026 06:44:19 +0000. Up 6.81 seconds."
# boot_wall = that date - that uptime. No in-guest agent required.
#
# Usage:
#   ./scripts/phase-timings.sh                      # deploy + measure, 1 run
#   ./scripts/phase-timings.sh --runs 3             # 3 clean runs, median
#   ./scripts/phase-timings.sh --collect-only       # table for the CURRENT
#                                                   #   cluster, no deploy
#   ./scripts/phase-timings.sh --variant warm --no-clean
#
# --collect-only is the safe way to validate the collectors: it mutates nothing
# and reconstructs the table for whatever VMs are running right now (a KubeVirt
# restart of a containerDisk VM is a genuine first boot, so it is a valid
# sample — minus the CAPI chain, which only a fresh apply exercises).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VARIANT="warm"
RUNS=1
DO_CLEAN=1
COLLECT_ONLY=0
CLUSTER_NAME="${CLUSTER_NAME:-target-cluster}"
NS="${NAMESPACE:-default}"
VIP="${API_LB_IP:-172.18.255.215}"
TIMEOUT="${TIMEOUT:-300}"
OUT_DIR="${OUT_DIR:-${TMPDIR:-/tmp}/phase-timings-$$}"

while [ $# -gt 0 ]; do
  case "$1" in
    --variant)      VARIANT="$2"; shift 2 ;;
    --runs)         RUNS="$2"; shift 2 ;;
    --no-clean)     DO_CLEAN=0; shift ;;
    --collect-only) COLLECT_ONLY=1; DO_CLEAN=0; shift ;;
    --out)          OUT_DIR="$2"; shift 2 ;;
    -h|--help)      sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT_DIR"

# ── helpers ──────────────────────────────────────────────────────────────────

# epoch seconds (float) from an RFC3339 / RFC2822 timestamp; empty on failure
to_epoch() { [ -n "${1:-}" ] && date -d "$1" +%s.%N 2>/dev/null || true; }

# fixed-point subtraction that tolerates empty operands
delta() {
  local a="${1:-}" b="${2:-}"
  [ -z "$a" ] || [ -z "$b" ] && { echo ""; return; }
  awk -v a="$a" -v b="$b" 'BEGIN{printf "%.1f", a-b}'
}

fmt() { # print a phase row: label, offset-from-t0, duration
  printf '  %-46s %8s %8s\n' "$1" "${2:-—}" "${3:-—}"
}

kg() { timeout 25 kubectl -n "$NS" "$@" 2>/dev/null; }

# first bracketed kernel timestamp on a console line matching $2, from file $1.
# NOT anchored to start-of-line: the getty prompt interleaves with kernel output
# ("target-cluster-cp login: [   15.738316] cloud-init[976]: ..."), so an
# anchored match silently drops exactly the late lines we care about. The float
# requirement keeps it from matching a pid like "cloud-init[976]".
console_up() {
  grep -aE "$2" "$1" 2>/dev/null | head -1 |
    sed -nE 's/.*\[[[:space:]]*([0-9]+\.[0-9]+)\].*/\1/p'
}

# boot wall-clock epoch, derived from any cloud-init "at <date>. Up <n> seconds"
console_boot_epoch() {
  local line d up
  line=$(grep -aE "running '(init-local|init|modules:config|modules:final)' at .*Up [0-9.]+ seconds" "$1" 2>/dev/null | head -1)
  [ -z "$line" ] && return
  d=$(sed -nE "s/.* at ([A-Z][a-z]{2}, [0-9]{2} [A-Z][a-z]{2} [0-9]{4} [0-9:]{8} [+-][0-9]{4})\..*/\1/p" <<<"$line")
  up=$(sed -nE 's/.*Up ([0-9.]+) seconds.*/\1/p' <<<"$line")
  local e; e=$(to_epoch "$d")
  [ -n "$e" ] && [ -n "$up" ] && awk -v e="$e" -v u="$up" 'BEGIN{printf "%.3f", e-u}'
}

# ── probe: first TCP accept and first HTTP 200 on the API VIP ────────────────
start_probe() {
  local f="$1"; : >"$f"
  (
    local tcp="" ok=""
    while [ -z "$ok" ]; do
      if [ -z "$tcp" ] && timeout 1 bash -c "</dev/tcp/${VIP}/6443" 2>/dev/null; then
        tcp=$(date +%s.%N); echo "tcp=$tcp" >>"$f"
      fi
      if [ "$(timeout 2 curl -ks -o /dev/null -w '%{http_code}' "https://${VIP}:6443/readyz" 2>/dev/null)" = "200" ]; then
        ok=$(date +%s.%N); echo "readyz=$ok" >>"$f"
      fi
      sleep 0.25
    done
  ) >/dev/null 2>&1 &
  # The redirect above is load-bearing: this function's output is read via
  # command substitution, which blocks until EVERY process holding the pipe's
  # write end exits. Without it the backgrounded probe (which only exits once
  # the API answers) deadlocks the caller before it can even apply the manifest.
  echo $!
}

# ── one measurement run ──────────────────────────────────────────────────────
# Populates the RESULT_* globals. Returns non-zero if the cluster never came up.
run_once() {
  local run_id="$1" t0 probe_pid probe_file kubeconfig
  probe_file="$OUT_DIR/probe.$run_id"
  kubeconfig="$OUT_DIR/kubeconfig.$run_id"

  if [ "$COLLECT_ONLY" = 0 ]; then
    if [ "$DO_CLEAN" = 1 ]; then
      echo "==> tearing down any existing $CLUSTER_NAME"
      kubectl delete cluster "$CLUSTER_NAME" --ignore-not-found --wait=true >/dev/null 2>&1
      local w=0
      while [ "$w" -lt 120 ]; do
        [ -z "$(kg get vmi -o name | grep "$CLUSTER_NAME" || true)" ] &&
        [ -z "$(kg get vm  -o name | grep "$CLUSTER_NAME" || true)" ] && break
        sleep 2; w=$((w+2))
      done
      echo "    gone after ${w}s"
    fi

    echo "==> host: $(uptime | sed 's/.*load average/load/')"
    echo "    mem available: $(free -g | awk '/^Mem:/{print $7}')Gi"

    ./scripts/seed-cluster-secrets.sh >/dev/null || { echo "seed failed" >&2; return 1; }

    probe_pid=$(start_probe "$probe_file")
    t0=$(date +%s.%N)
    IMAGE_VARIANT="$VARIANT" ./scripts/render-cluster.sh 2>/dev/null | kubectl apply -f - >/dev/null ||
      { kill "$probe_pid" 2>/dev/null; echo "apply failed" >&2; return 1; }
  else
    probe_pid=""
    t0=""
  fi

  # ── wait for both nodes Ready ──
  local elapsed=0 ready=0
  while [ "$elapsed" -lt "$TIMEOUT" ]; do
    clusterctl get kubeconfig "$CLUSTER_NAME" >"$kubeconfig" 2>/dev/null || true
    if [ -s "$kubeconfig" ]; then
      ready=$(KUBECONFIG="$kubeconfig" timeout 10 kubectl get nodes \
        -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' \
        2>/dev/null | grep -c '^True$')
      [ "${ready:-0}" -ge 2 ] && break
    fi
    [ "$COLLECT_ONLY" = 1 ] && [ "$elapsed" -ge 20 ] && break
    printf '\r    ready %s/2  [%ss]' "${ready:-0}" "$elapsed"
    sleep 1; elapsed=$((elapsed+1))
  done
  echo ""
  [ -n "$probe_pid" ] && kill "$probe_pid" 2>/dev/null
  if [ "${ready:-0}" -lt 2 ]; then
    echo "TIMEOUT: only ${ready:-0}/2 nodes Ready after ${elapsed}s" >&2
    return 1
  fi

  # ── identify the objects ──
  local cp_vmi wk_vmi cp_pod wk_pod
  cp_vmi=$(kg get vmi -o name | sed 's|.*/||' | grep -- "-cp-" | head -1)
  wk_vmi=$(kg get vmi -o name | sed 's|.*/||' | grep -- "-workers-" | head -1)
  cp_pod=$(kg get pods -l kubevirt.io=virt-launcher -o name | sed 's|.*/||' | grep -- "-cp-" | head -1)
  wk_pod=$(kg get pods -l kubevirt.io=virt-launcher -o name | sed 's|.*/||' | grep -- "-workers-" | head -1)

  # ── console logs ──
  local cp_con="$OUT_DIR/console-cp.$run_id" wk_con="$OUT_DIR/console-wk.$run_id"
  timeout 60 kubectl -n "$NS" logs "$cp_pod" -c guest-console-log 2>/dev/null | tr -d '\r' >"$cp_con"
  timeout 60 kubectl -n "$NS" logs "$wk_pod" -c guest-console-log 2>/dev/null | tr -d '\r' >"$wk_con"

  # ── anchor: t0 ──
  # Fresh deploy: t0 = the apply. Collect-only: t0 = earliest VMI creation.
  if [ -z "$t0" ]; then
    t0=$(to_epoch "$(kg get vmi "$cp_vmi" -o jsonpath='{.metadata.creationTimestamp}')")
    T0_LABEL="VMI created (no apply timestamp in --collect-only)"
  else
    T0_LABEL="kubectl apply"
  fi

  # ── CAPI controller chain ──
  CAPI_CLUSTER=$(to_epoch "$(kg get cluster "$CLUSTER_NAME" -o jsonpath='{.metadata.creationTimestamp}')")
  CAPI_VM=$(to_epoch "$(kg get vm -o jsonpath="{.items[?(@.metadata.name=='$cp_vmi')].metadata.creationTimestamp}")")
  CAPI_VMI=$(to_epoch "$(kg get vmi "$cp_vmi" -o jsonpath='{.metadata.creationTimestamp}')")

  # ── KubeVirt: pod → qemu ──
  local -a nodes=("cp:$cp_vmi:$cp_pod:$cp_con" "wk:$wk_vmi:$wk_pod:$wk_con")
  for spec in "${nodes[@]}"; do
    IFS=: read -r tag vmi pod con <<<"$spec"
    # Anchor phase A on the launcher POD's own creation. VMI phase timestamps and
    # pod container timestamps are both 1s-granular but come from different
    # clocks/writers, so mixing them yields negative durations.
    eval "${tag}_PODCREATED=\$(to_epoch \"\$(kg get pod \$pod -o jsonpath='{.metadata.creationTimestamp}')\")"
    eval "${tag}_SCHED=\$(to_epoch \"\$(kg get vmi \$vmi -o jsonpath='{.status.phaseTransitionTimestamps[?(@.phase==\"Scheduled\")].phaseTransitionTimestamp}')\")"
    eval "${tag}_RUNNING=\$(to_epoch \"\$(kg get vmi \$vmi -o jsonpath='{.status.phaseTransitionTimestamps[?(@.phase==\"Running\")].phaseTransitionTimestamp}')\")"
    # volumesystemdisk is an INIT container (one-shot, copies the containerDisk),
    # so it lands in initContainerStatuses and is already terminated by the time
    # we look. guest-console-log is a native sidecar and stays running.
    eval "${tag}_DISK=\$(to_epoch \"\$(kg get pod \$pod -o jsonpath='{.status.initContainerStatuses[?(@.name==\"volumesystemdisk\")].state.terminated.startedAt}')\")"
    eval "${tag}_CONSOLE=\$(to_epoch \"\$(kg get pod \$pod -o jsonpath='{.status.initContainerStatuses[?(@.name==\"guest-console-log\")].state.running.startedAt}')\")"
    eval "${tag}_COMPUTE=\$(to_epoch \"\$(kg get pod \$pod -o jsonpath='{.status.containerStatuses[?(@.name==\"compute\")].state.running.startedAt}')\")"

    # guest boot anchor + in-guest milestones
    local boot; boot=$(console_boot_epoch "$con")
    eval "${tag}_BOOT=\$boot"
    local u
    for m in "INIT:Run /init as init process" \
             "SYSTEMD:systemd\[1\]: systemd [0-9]" \
             "CIFINAL:running 'modules:final'" \
             "K3SSTART:\[airgap-install\] Mode:" \
             "K3SREADY:\[airgap-install\] .* started"; do
      u=$(console_up "$con" "${m#*:}")
      if [ -n "$boot" ] && [ -n "$u" ]; then
        eval "${tag}_${m%%:*}=\$(awk -v b=\"\$boot\" -v u=\"\$u\" 'BEGIN{printf \"%.3f\", b+u}')"
      else
        eval "${tag}_${m%%:*}="
      fi
    done
  done

  # ── node Ready (the metric) ──
  cp_READY=$(to_epoch "$(KUBECONFIG="$kubeconfig" timeout 10 kubectl get node "$cp_vmi" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}' 2>/dev/null)")
  wk_READY=$(to_epoch "$(KUBECONFIG="$kubeconfig" timeout 10 kubectl get node "$wk_vmi" -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastTransitionTime}' 2>/dev/null)")

  PROBE_TCP=$(sed -nE 's/^tcp=(.*)/\1/p' "$probe_file" 2>/dev/null | head -1)
  PROBE_READYZ=$(sed -nE 's/^readyz=(.*)/\1/p' "$probe_file" 2>/dev/null | head -1)

  RESULT_T0="$t0"
  RESULT_TOTAL=$(delta "$(awk -v a="${cp_READY:-0}" -v b="${wk_READY:-0}" 'BEGIN{print (a>b)?a:b}')" "$t0")
  return 0
}

# ── table ────────────────────────────────────────────────────────────────────
print_table() {
  local t0="$RESULT_T0"
  echo ""
  echo "  phase                                            t+(s)   dur(s)"
  echo "  ────────────────────────────────────────────────────────────────"
  if [ "$COLLECT_ONLY" = 1 ]; then
    echo "  [chain] CAPI controllers — N/A in --collect-only (objects predate this boot)"
  else
    echo "  [chain] CAPI controllers ($T0_LABEL → VMI)"
    fmt "Cluster object created"      "$(delta "$CAPI_CLUSTER" "$t0")"
    fmt "VirtualMachine created"      "$(delta "$CAPI_VM" "$t0")"       "$(delta "$CAPI_VM" "$CAPI_CLUSTER")"
    fmt "VMI created"                 "$(delta "$CAPI_VMI" "$t0")"      "$(delta "$CAPI_VMI" "$CAPI_VM")"
  fi

  for tag in cp wk; do
    local label; [ "$tag" = cp ] && label="CONTROL PLANE" || label="WORKER"
    eval "local sched=\$${tag}_SCHED disk=\$${tag}_DISK compute=\$${tag}_COMPUTE podc=\$${tag}_PODCREATED"
    eval "local running=\$${tag}_RUNNING boot=\$${tag}_BOOT init=\$${tag}_INIT"
    eval "local sysd=\$${tag}_SYSTEMD cifinal=\$${tag}_CIFINAL"
    eval "local k3sstart=\$${tag}_K3SSTART k3sready=\$${tag}_K3SREADY rdy=\$${tag}_READY"
    echo ""
    echo "  [$label]"
    fmt "A launcher pod created"      "$(delta "$podc" "$t0")"
    fmt "A pod Scheduled"             "$(delta "$sched" "$t0")"       "$(delta "$sched" "$podc")"
    fmt "A containerDisk unpacked"    "$(delta "$disk" "$t0")"        "$(delta "$disk" "$podc")"
    fmt "A compute started"           "$(delta "$compute" "$t0")"     "$(delta "$compute" "$disk")"
    fmt "A VMI Running (qemu)"        "$(delta "$running" "$t0")"     "$(delta "$running" "$compute")"
    fmt "B kernel printk 0.000"       "$(delta "$boot" "$t0")"        "$(delta "$boot" "$running")"
    fmt "B initramfs /init"           "$(delta "$init" "$t0")"        "$(delta "$init" "$boot")"
    fmt "C systemd PID 1"             "$(delta "$sysd" "$t0")"        "$(delta "$sysd" "$init")"
    fmt "C cloud-init modules:final"  "$(delta "$cifinal" "$t0")"     "$(delta "$cifinal" "$sysd")"
    fmt "C k3s start issued"          "$(delta "$k3sstart" "$t0")"    "$(delta "$k3sstart" "$cifinal")"
    fmt "D k3s reports started"       "$(delta "$k3sready" "$t0")"    "$(delta "$k3sready" "$k3sstart")"
    fmt "E node Ready"                "$(delta "$rdy" "$t0")"         "$(delta "$rdy" "$k3sready")"
  done

  echo ""
  echo "  [API VIP probe]"
  fmt "first TCP accept on :6443"     "$(delta "$PROBE_TCP" "$t0")"
  fmt "first HTTP 200 /readyz"        "$(delta "$PROBE_READYZ" "$t0")" "$(delta "$PROBE_READYZ" "$PROBE_TCP")"
  echo ""
  echo "  ════════════════════════════════════════════════════════════════"
  printf '  TOTAL time-to-ready (both nodes)               %8s\n' "${RESULT_TOTAL:-—}"
  echo ""
}

# ── main ─────────────────────────────────────────────────────────────────────
echo "phase-timings: variant=$VARIANT runs=$RUNS collect_only=$COLLECT_ONLY"
echo "artifacts: $OUT_DIR"
TOTALS=()
for i in $(seq 1 "$RUNS"); do
  echo ""
  echo "━━━ run $i/$RUNS ━━━"
  if run_once "$i"; then
    print_table | tee "$OUT_DIR/table.$i"
    TOTALS+=("$RESULT_TOTAL")
  else
    echo "run $i FAILED — not counted" >&2
  fi
done

if [ "${#TOTALS[@]}" -gt 1 ]; then
  echo "totals: ${TOTALS[*]}"
  printf 'median: %s\n' "$(printf '%s\n' "${TOTALS[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
fi
