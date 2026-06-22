# Warm VM Pool / Pre-Deployed Standby — Strategy & Spec

## TL;DR

Image pre-initialization (`:preinit`, `:warm`) does **not** speed up time-to-Ready —
measured head-to-head, warm ≈ parallel ≈ **~50s** on this host (see
`docs/sub-60s-cluster-strategy.md` and the warm-path memory). The bottleneck is
work that pre-init can't touch:

```
0→17s   both VMs boot to Running        (KubeVirt schedule + kernel + cloud-init)
17→34s  CP k3s start → API readyz=ok    (apiserver/controller/scheduler/kubelet)
34→52s  worker join + both nodes Ready  (agent can't join until CP API is up)
```

The only way under 40s — really, to **single-digit seconds** — is to do this work
**before the user asks**, then hand the result over. For a single-cluster-at-a-time
deployment that is not a classic N-slot VM pool; it is a **size-1 pre-deployed
standby**: always keep one warm `target-cluster` built and idle, "deploy" = claim
it (near-instant), "delete" = tear down + rebuild the standby in the background.

This reuses the **existing CAPI deploy path unchanged** — the pool layer just runs
that deploy proactively and tracks claim state.

---

## 1. Why pre-booting is the only remaining lever

Each phase above is intrinsic to building a cluster from cold VMs:

- **VM boot (17s)** — fixed cost of scheduling a virt-launcher pod + booting the
  guest. Pre-init can't help; only *not booting at deploy time* helps.
- **k3s control-plane start (17s)** — apiserver/controller/scheduler/kubelet
  process startup. Warm datastore saves cert-gen + chart-apply, but those are
  async / off the path to node-Ready, so it nets ~0.
- **worker join (18s)** — serialized *after* CP API is up by construction (the
  agent needs the API to join). Parallel boot already overlaps the *boot*, but
  the *join* still waits for the CP.

A warm pool removes the first phase entirely (VM already booted) and can remove
most of the second and third (k3s already running, worker already joined).

### Hard constraint that makes this tractable: stable IPs

KubeVirt VMs on Kind get a pod IP from the CNI when the virt-launcher pod starts.
That IP is what broke the etcd path in the warm-image experiment (member URL is
IP-bound → needs `--cluster-reset` on every new IP). **A pooled VM that stays
alive keeps its pod IP**, so:

- embedded etcd works with no rehoming (can keep `cluster-init: true`), and
- the baked serving cert SANs (incl. the MetalLB VIP `172.18.255.215`) stay valid.

This is why "keep the VM alive" beats "snapshot + restore" (restore re-creates the
PVC and reboots → new IP → back to square one).

---

## 2. Design levels

### Level 0 — today (baseline)
On-demand CAPI deploy. ~50s, 0 idle cost. (`target-cluster-parallel.yaml`.)

### Level 1 — Pre-deployed standby  ⭐ RECOMMENDED

Keep exactly one warm `target-cluster` built and idle. Because only one cluster
runs at a time, the standby *is* the cluster the user will get.

**Lifecycle state machine** (one cluster object, tracked via a label
`pool.local/state`):

```
        (none)
          │  pool controller builds via CAPI (~50s, background)
          ▼
        WARM ──────claim (UI Deploy)──────▶ CLAIMED
          ▲                                    │
          │ controller rebuilds (~50s, bg)     │ UI Delete
          └──────────── (none) ◀── DRAINING ◀──┘
                        kubectl delete cluster
```

- **Deploy/claim**: if a `WARM` cluster exists → label it `CLAIMED`, return its
  kubeconfig/status immediately. **Time-to-ready ≈ a few seconds** (it is already
  Ready). If none exists (cold start, or claimed-then-deleted before rebuild
  finished) → fall back to today's live build (~50s, stream logs as now).
- **Delete**: `kubectl delete cluster target-cluster` → controller sees no
  `WARM` standby → rebuilds one in the background.
- **Freshness**: every standby is a freshly-built cluster with no user workloads,
  so a claim always yields a clean cluster. After a delete, the rebuild guarantees
  the next claim is fresh too.

**Resource cost**: one cluster running while idle.
- full profile = 8Gi CP + 6Gi worker = **14Gi**
- lite profile = 4Gi + 4Gi = **8Gi**
- Host has ~21Gi free → a single full standby fits. At no point do two clusters
  run (standby becomes the claimed cluster; rebuild happens only *after* teardown),
  so peak stays ~14Gi.
- If you also want a standby ready *while* a cluster is in use (instant
  re-deploy), you need both alive at once → use **lite** (16Gi total, fits).

**Identity**: single-cluster-at-a-time means reusing the fixed CA/token
(`03-target-cluster/warm-ca/`, the `f00dcafe…` token) is safe and simplest — no
per-cluster cert generation. The warm path's seed step (`seed-cluster-secrets.sh`)
runs once per rebuild. (If you ever allow concurrent clusters, switch to
per-build random identity.)

**What to build**:
1. **Pool controller** — a reconcile loop: "if no Cluster labeled
   `pool.local/state in (WARM,CLAIMED)` exists, build one via the existing deploy
   and label it `WARM` once 2/2 Ready." Cheapest form: a goroutine in the existing
   Go backend (`ui/backend`), or a standalone `scripts/pool-controller.sh` run as
   a systemd unit / Deployment. Reuses `runDeployment(...)` from
   `ui/backend/handlers/cluster_deploy.go`.
2. **Claim/delete API** — extend `cluster_deploy.go`:
   - `POST /api/v1/cluster/deploy` → if a `WARM` cluster exists, relabel
     `CLAIMED`, emit a synthetic "ready" SSE and return; else current behavior.
   - delete handler → after delete, signal the controller to rebuild.
3. **UI** — no visual change required; "Deploy" just resolves in seconds when a
   standby is hot. Optionally show a "standby ready" indicator.

**Effort**: ~1–2 days. Low risk — it sits *on top of* the proven CAPI path; worst
case (no standby) degrades to today's behavior.

### Level 2 — Paused warm VM pool (only if you need >1 cluster or instant rebuild)

KubeVirt `pause` freezes a running VM's vCPUs while keeping its RAM and pod IP.
A pool of *paused* CP/worker VMs (k3s already running and Ready before pause)
resumes in <1s with IP and etcd intact.

- **Claim** = unpause + a light "re-tenant" step (delete prior node objects / any
  leftover workloads; the API/etcd are already warm). Seconds.
- **Return** = re-pause after cleanup, or destroy + replenish.
- **Cost**: paused VMs hold full RAM (no savings while idle) → N×14Gi. With 21Gi
  free, realistically N=1 full or N=2 lite.
- **Complexity**: needs a real controller managing pause/unpause, claim ledger,
  health/eviction, and re-tenant cleanup. This is where the classic "pool"
  machinery lives. Only worth it if Level 1's single standby is insufficient
  (e.g., you want a hot spare *and* an active cluster simultaneously, or sub-second
  rebuilds).
- **Snapshot/restore variant** (CRDs are available): snapshot a warm cluster, and
  on deploy `VirtualMachineRestore`. Rejected as the primary path — restore
  re-provisions the PVC and **reboots**, so you pay the 17s boot again *and* get a
  new IP (etcd rehoming returns). Useful only for cheap *replenishment* of the
  pool, not for the fast claim.

---

## 3. Recommended plan

1. **Ship Level 1 (pre-deployed standby).** Biggest win (claim in seconds), lowest
   risk, minimal new code, full profile fits in RAM. Covers the demo flow
   (deploy → show → delete → background rebuild → next deploy is instant).
2. Use the **existing parallel image** for the standby build — warm/preinit add no
   speed and the standby builds off the user's clock anyway, so prefer the simplest
   known-good image (`:latest` + `target-cluster-parallel.yaml`). (The `:warm`
   artifacts can stay as a documented experiment or be reverted.)
3. **Defer Level 2** unless a concrete need for concurrent clusters or
   instant-rebuild appears. It's a multi-day controller with ongoing maintenance.

### MVP checklist (Level 1)
- [ ] Label scheme `pool.local/state` on the `Cluster`.
- [ ] Pool controller loop (goroutine or script) that keeps one `WARM` standby.
- [ ] Claim path in the deploy handler (relabel + instant return when WARM exists).
- [ ] Delete path triggers background rebuild.
- [ ] Idle-cost guard: profile = full by default; document the lite option for
      "hot spare while active."
- [ ] Health watchdog: if the WARM standby goes unhealthy/NotReady while idle,
      rebuild it.

---

## 4. Limitations & honest caveats

- **Not always instant.** First deploy after a cold start, or a deploy issued
  before a post-delete rebuild finishes, still pays ~50s. The win is for the steady
  state where a standby is pre-built.
- **Idle resource cost.** One cluster always running (~14Gi full / 8Gi lite).
- **Single-cluster assumption baked in.** Reusing fixed identity and a size-1
  standby both rely on it. Concurrency needs Level 2 + per-cluster identity.
- **Standby drift/health.** A long-idle standby must be watched and rebuilt if it
  degrades; otherwise "instant deploy" hands over a sick cluster.
