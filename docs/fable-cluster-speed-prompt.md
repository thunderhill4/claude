# Task: cut target-cluster time-to-ready below 48.5s

Repo: /mnt/mil. Work on a branch off `feat/istio-1.30-demo-and-sympozium-0.10.47`.

## The one number

`target-cluster` time-to-ready = wall time from `kubectl apply` of the cluster
manifest until **both** nodes report `Ready` via the target kubeconfig. That is what
`scripts/time-to-ready.sh` measures. It is the only metric that counts. Optimise the
**cold build** path (`make target-cluster` / `make time-to-ready-warm`), not the UI
Deploy click — the warm pool already answers the click in 194 ms.

**Baseline to beat: 48.5s** (`make time-to-ready-warm`, cold, quiet host, 2 nodes Ready).

## Ground truth — measured, not assumed

Phase budget of those ~48s (from `docs/warm-pool-strategy.md` §1):

```
 0 → 17s   both VMs boot to Running     (virt-launcher schedule + kernel + cloud-init)
17 → 34s   CP k3s start → API ready     (apiserver/controller/scheduler/kubelet)
34 → 52s   worker joins → both Ready    (agent cannot join before the CP API answers)
```

Measured variants on this host:

| Path | Time to 2 nodes Ready |
|---|---|
| legacy `:latest`, sequential worker | 90–150s |
| `:preinit` image | ~136s |
| `target-cluster-parallel.yaml` (`:latest`, cold init) | 46.6 / 49.7 / 50.0s |
| `target-cluster-warm.yaml` (`:warm` image + seeded CAs) | **48.5s** |
| warm-pool claim (pre-built standby) | 194 ms |

## Do NOT retry these — they are settled negative results

1. **Baking more state into the golden image.** `:preinit` (preserve `/server/db` +
   `/server/tls`) came out at ~136s, *slower* than legacy, because CAPK injects fresh
   per-cluster CAs via cloud-init `write_files` and the bake-signed leaf certs must
   then be purged, forcing `k3s server --cluster-reset`. Details:
   `docs/sub-60s-cluster-strategy.md` §3.3.
2. **The `:warm` image (fixed CAs + token, no reset).** It works exactly as designed
   and delivers **no speedup**: 48.5s vs 46.6–50.0s for the plain parallel build —
   statistically identical. Reason: what warm pre-computes (certs, CRDs, system
   charts) is off the critical path to node-Ready; charts apply asynchronously.
3. **Parallelising the worker boot.** Already done
   (`target-cluster-parallel.yaml`: pre-seeded token + static `bootstrap.dataSecretName`
   + `machineset.cluster.x-k8s.io/skip-preflight-checks: All`). The worker *boot* is
   already overlapped with the CP; the worker *join* is still gated on the CP API and
   that is intrinsic.

**`/mnt/mil/CLAUDE.md` contradicts this.** It says the warm path "targets
time-to-ready <40s" and describes it as the fast path. That is a stale aspiration,
never achieved. Where CLAUDE.md and the table above disagree, the table wins. Do not
let CLAUDE.md steer you back into levers 1–3.

## Step 1 (mandatory, before any optimisation): instrument the phases

There is currently **no per-phase timing anywhere in the repo** —
`scripts/time-to-ready.sh` prints one total and nothing else. Every optimisation
attempt so far has been evaluated against a single aggregate number, which is why
two dead ends took a full bake cycle each to disprove.

Write `scripts/phase-timings.sh` that emits, for one deploy, the wall-clock offset of
at least:

- `VMI created` → `VMI Running` (CP and worker separately)
- guest boot: kernel start → cloud-init finished (`systemd-analyze` inside the guest;
  SSH key and user `ubuntu` are baked in, see the `preK3sCommands` in
  `03-target-cluster/target-cluster-warm.yaml`)
- k3s server start → first `200` from `/readyz` on the VIP
- MetalLB binding `172.18.255.215` → first successful TCP connect on `:6443`
- worker `k3s-agent` start → worker Node object created → worker Node Ready
- CP Node Ready, worker Node Ready

Run it against the current 48.5s path and report the real breakdown. **The 17/17/18
split above is a coarse estimate — confirm or correct it before acting on it.** If it
is wrong, say so; that finding alone is worth more than a speculative patch.

## Step 2: only then, pick levers — bounded to these

**Phase A — VM boot (~17s).** Guest boot is completely uninstrumented.
`bake-common.sh` step 4d masks `snapd`, `multipathd`, `apt-daily*`, `motd-news`,
`unattended-upgrades`. It does **not** touch `systemd-networkd-wait-online`, the GRUB
menu timeout, `udev settle`, or cloud-init's stage split. Check what
`systemd-analyze critical-chain` actually blames before changing any of them.
Separately: how much of the 17s is virt-launcher pod scheduling + containerDisk
attach, i.e. outside the guest entirely?

**Phase B — k3s CP start (~17s).** The warm config disables only `servicelb` and
`traefik` (`bake-common.sh` step 5-warm, and `serverConfig.disableComponents` in the
manifest). Untested: `metrics-server`, `local-storage`, the helm controller, network
policy, `--disable-cloud-controller`. Measure which of these actually sit between
process start and `/readyz` ok — several may already be async and worth nothing.

**Phase C — worker join (~18s).** The worker's k3s-agent retries the static VIP
`172.18.255.215:6443` until it answers. Two questions worth real measurement:
(a) how long after CP API readiness does MetalLB actually bind and route the VIP, and
(b) after the API is genuinely reachable, how much dead time does the agent's retry
backoff add before the next attempt? A fixed backoff sitting on the critical path is
the single most likely cheap win in the whole pipeline. Also check whether worker
Node-Ready waits on flannel CNI coming up on that node.

**Phase D — structural (largest upside, no bake required).** The warm pool
(`ui/backend/handlers/pool.go`) already claims in 194 ms but:
- it is opt-in — `run-ui.sh` sets `POOL_ENABLED=false`;
- it only lives as long as the `go run .` backend process, so the CLI path
  (`make target-cluster`) never benefits;
- its standby builds from `POOL_STANDBY_MANIFEST` defaulting to
  `03-target-cluster/target-cluster-parallel.yaml` (`:latest`), not the warm manifest.
Making the standby survive independently of the UI process, and reachable from the
CLI path, converts the 48.5s into ~0.2s for the common case without touching the
boot path at all. Level 2 (paused KubeVirt VM pool) is specced in
`docs/warm-pool-strategy.md` §2 and has never been built.

Report which phase you are attacking and why, before you change code.

## Measurement protocol — non-negotiable

The host is noisy: `cluster1`, `cluster2`, and three `ragd-*` containers are running,
and an earlier run of this work recorded 35s times that turned out to be quiet-host
luck rather than a real improvement. So:

1. Before every run: `make clean`, then poll until no `target-cluster*` VM objects
   remain. A stale cluster is already present (19 days old, `AVAILABLE False`) — tear
   it down first and confirm it is gone.
2. Record host load (`uptime`, free RAM) immediately before each run.
3. **N=3 runs minimum, report median and full spread.** A single fast run is not
   evidence.
4. Re-measure the baseline in the same session as the candidate. Do not compare
   against the 48.5s figure from a different day.
5. Change one variable at a time.

## Acceptance

Median time-to-ready **< 40s** over 3 clean runs, with before/after measured in the
same session on the same host state, and `make verify` passing afterwards.

**"No lever found" is an acceptable and valuable outcome.** If the phase timings show
the remaining cost is irreducible under CAPK + KubeVirt, say so, write it up as a
third documented dead end alongside the other two, and recommend the structural
(Phase D) path instead. Do not ship a change you cannot demonstrate with numbers.

## Output

1. The measured phase breakdown (Step 1), as a table.
2. The lever you chose and the reasoning that ruled out the others.
3. Before/after numbers, 3 runs each, with host-load notes.
4. The diff.
5. An update to `docs/sub-60s-cluster-strategy.md` recording the result — positive or
   negative — and a correction to the `<40s` claim in `CLAUDE.md` if it still does not
   hold.

Do not claim anything is faster until you have pasted the timing output that shows it.
