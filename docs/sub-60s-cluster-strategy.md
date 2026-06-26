# Sub-60s Target Cluster Provisioning — Strategy, Attempts, and What's Next

## TL;DR

- **Baseline (legacy `:latest` image):** 90–150s time-to-ready (p95).
- **Current (`:preinit` image, Phase 1 shipped):** ~136s in the one measurement we have.
- **Target:** <60s p95.
- **Gap:** we have **not** broken past the legacy band. The change that was supposed to deliver the speedup (preserving k3s state in the golden image) is neutralized by CAPK's bootstrap model — explained below.
- **Path to <60s:** requires one of the "Option B/C" strategies in §5, not more tuning of the current approach.

---

## 1. The provisioning pipeline (what takes time)

```
kubectl apply -f <cluster.yaml>
  → CAPI Cluster created                                             (~1s)
  → CAPK DataVolume clone kicks off                                  (0s if pre-pulled)
  → KubeVirt VMI scheduled → Pending → Running                       (~30–60s, dominated by clone if not pre-pulled)
  → cloud-init: write_files (CAs, config.yaml) + runcmd              (~5–10s)
  → /opt/install.sh: systemctl enable+start k3s                      (~1s)
  → k3s.service ExecStartPre = firstboot-regen.sh
      → k3s server --cluster-reset                                    (~20–30s)
  → k3s.service ExecStart = k3s server                                (~10–20s)
  → CAPK control-plane service + MetalLB IP binding                   (~5–10s)
  → KThreesControlPlane marks `Initialized`                           (~5s)
  → MachineDeployment creates worker VMI                              (starts AFTER CP is Ready)
  → worker VMI Running → k3s-agent joins                              (~30–60s)
──────────────────────────────────────────────────────────────────────
Total observed (preinit): ~136s                Target: <60s
```

Note the serialization: **the worker VM doesn't even start booting until the control-plane is `Ready`**. That's ~60s we can't reclaim without parallelizing or pre-booting.

---

## 2. What was tried (Phase 1 as planned)

The plan lived at [`/home/mahipal/.claude/plans/this-is-a-longterm-humming-moon.md`](the approved Phase 1–5 plan).

Phase 1 bake (`bake-common.sh`) preserved full k3s state in the golden image:
- `/var/lib/rancher/k3s/server/db/` — etcd DB with CRDs, RBAC, system charts
- `/var/lib/rancher/k3s/server/tls/` — CA + leaf certs
- `/var/lib/rancher/k3s/agent/images/` — airgap tarballs
- `firstboot-regen.sh` installed as k3s.service `ExecStartPre`

Hypothesis: first boot runs `k3s server --cluster-reset` (keeps DB, issues fresh etcd cluster ID), so each new cluster skips cold etcd bootstrap, cert gen, bootstrap-data write, system-chart apply. Estimated savings: 30–60s.

---

## 3. What failed, and how it was fixed

### 3.1 Clone DataVolume stuck at `WaitForFirstConsumer`

**Symptom:** `ubuntu-noble-k3s-preinit` DV sat at WFFC phase indefinitely; bake loop polled "DataVolume phase: …" with no progress.

**Root cause:** the default storage class uses WaitForFirstConsumer binding — CDI defers the import until a pod actually mounts the PVC. No pod = no mount = no progress.

**Fix:** added `cdi.kubevirt.io/storage.bind.immediate.requested: "true"` annotation on the import DV in `scripts/import-base-images.sh`.

### 3.2 Source DV `ubuntu-noble-dv` missing

**Symptom:** CDI reported `CloneWithoutSource: The source pvc ubuntu-noble-dv doesn't exist`. The repo assumes the base Ubuntu cloud image is imported but has no script to do it.

**Fix:** added `scripts/import-base-images.sh` that imports both `ubuntu-noble-dv` (~600 MB) and `ubuntu-minimal-noble-dv` (~300 MB) from the Ubuntu cloud-images HTTP URLs via CDI `http:` source.

### 3.3 CA-injection conflict → `k3s --cluster-reset` infinite loop

**Symptom (the big one):** cluster stuck at `KThreesControlPlane: WaitingForKthreesServer` for 20+ minutes. Inside the CP VM, k3s.service was `activating` (not `active`). The firstboot-regen log (`/var/log/k3s-firstboot-reset.log`) was spamming:

```
CA cert validation failed: Get "https://127.0.0.1:6444/cacerts":
  tls: failed to verify certificate: x509: certificate signed by unknown authority
```

**Root cause:** two-CA state on disk.
1. The bake generated k3s CAs (server-ca, client-ca, etcd/server-ca) during its warm-up init and signed every leaf cert (`client-admin.crt`, `serving-kube-apiserver.crt`, etc.) against them.
2. CAPK bootstrap writes **fresh per-cluster CAs** into the VM via cloud-init `write_files` — overwriting **only the `*-ca.crt` + `*-ca.key` files**, not the leaves.
3. So on first boot: CAs are CAPK's, but leaves + `dynamic-cert.json` + `cred/*.kubeconfig` are still bake-signed.
4. `k3s server --cluster-reset` starts its supervisor at `127.0.0.1:6444`, which presents a cert from `dynamic-cert.json` (bake-signed). The k3s client in the same process trusts `server-ca.crt` (CAPK's). Mismatch → retry forever.

This failure mode is invisible in design docs that only reason about etcd identity. It only showed up under real end-to-end boot.

**Fix:** in the CP's `preK3sCommands` (runs **after** CAPK `write_files` lands the fresh CAs, **before** k3s starts), purge everything in `/server/tls/` that isn't a CA:

```yaml
preK3sCommands:
  - rm -f /var/lib/rancher/k3s/server/token
  - find /var/lib/rancher/k3s/server/tls -type f
      ! -name '*-ca.crt' ! -name '*-ca.key' ! -name '*-ca.nochain.crt'
      -delete
```

k3s regenerates every leaf + `dynamic-cert.json` from the CAPK CAs on next start. `--cluster-reset` then validates cleanly, etcd comes up, API responds.

This fix is already in `03-target-cluster/target-cluster.tmpl.yaml` and `03-target-cluster/target-cluster-preinit-test.yaml`.

### 3.4 Why the fix neutralizes most of the speedup

The preservation-win plan assumed `/server/tls` survives to first boot. Since it doesn't (we purge it), k3s regenerates every leaf cert (~5–10s), and `--cluster-reset` (~20–30s) still runs to issue fresh etcd identity. The only real wins left:

- Pre-pulled airgap images → no CRD/system-chart download or apply.
- Preserved `/server/db` → RBAC and CRDs already in etcd (saves ~5–10s of initial apply).
- k3s binary + systemd unit baked in → no install-script download or first-boot compile.

Net: comparable to the tuned legacy `:latest` image. The sub-60s target needs a **different strategy**, not more tuning of this one.

---

## 4. What shipped (Phases 2–5, working)

Independent of the Phase 1 speedup result, the following are in and working:

- `bake-common.sh` — shared bake payload, parameterized by env.
- `bake-golden-image-minimal.sh` — Ubuntu Minimal variant (~300 MB base + k3s).
- `03-target-cluster/target-cluster.tmpl.yaml` — single manifest template driving both image variants.
- Backend renders + applies the template per deploy: `ui/backend/handlers/cluster_deploy.go` `runDeployment(profile, image)`.
- Make targets: `target-cluster-{lite,full}-{preinit,minimal}`, wired to `scripts/render-cluster.sh`.
- UI: profile + image variant toggles in `ClusterManager.tsx`, `api.deployCluster(profile, image)`.
- `scripts/import-base-images.sh`, `scripts/render-cluster.sh`, `scripts/time-to-ready.sh`.

So the multi-option UX — pick Noble or Minimal, pick lite or full — works end-to-end. What **doesn't** work is "sub-60s".

---

## 5. How to actually get under 60s

Ranked by likely impact and invasiveness.

### Option A (cheap, ~10–20s win) — Parallelize CP and worker boot

CAPK defaults to starting the worker only after CP is `Ready`. That's ~60s of serialized wait.

**Approach:** remove the MachineDeployment's implicit dependency by pre-creating the worker VMI before CP is Ready, then gate k3s-agent startup (not VM boot) on CP API availability.

- Worker's `kthreesConfigSpec.postK3sCommands` already waits for the supervisor URL. If the VM boots in parallel with CP, k3s-agent retries its join until CP serves — adds maybe 5–10s of idle retry, saves ~40s of serialized boot.
- Tradeoff: slight risk that worker k3s-agent retries burn log noise. Acceptable.

Projected: ~100s → **~75s**. Still not <60s.

### Option B (high impact, ~40–60s win) — Warm VM pool

The original plan flagged this as "out of scope, revisit if Phase 1 misses <60s" — which is where we are.

**Approach:** keep N pre-booted target-cluster VMs in a `Paused` state. On deploy, resume the pool, re-identify them as the new cluster (re-run firstboot-regen logic), and hand over.

- CP comes up in <10s (VM already booted, k3s already warm).
- Worker in parallel, same pool.
- Main cost shifts to pool maintenance, not user-visible deploy.

Projected: **20–40s** per deploy, once pool is warm.

Tradeoffs:
- Maintenance load: need to refresh pool after deletes.
- Memory: pool VMs consume RAM while idle.
- Identity re-issue at resume time is tricky — each cluster needs distinct etcd cluster ID, kubelet identity, node name. The `--cluster-reset` path we already have is the right primitive, but it has to run on resume without blocking.

### Option C (invasive, 30–50s win) — Skip `--cluster-reset` by renaming etcd member in place

The approved plan **rejected** this approach (etcd raft WAL has the cluster ID, renaming dirs won't reissue a cluster ID). But if `--cluster-reset` is the dominant cost and we can't eliminate it, forking the k3s-side logic to do an in-place metadata rewrite might be the only way.

**Approach:** stop k3s → `etcdutl` surgery to write new cluster ID into WAL + snapshot → restart. Risky (WAL format is internal) but avoids the 20–30s of `--cluster-reset`.

This is a research project, not a week of work.

### Option D (invasive, hard to estimate) — Custom bootstrap provider

CAPK writes CAs because it wants to manage cluster identity from the management cluster. A custom bootstrap provider (or a CAPK patch) could be told "the target cluster already has a CA — fetch it via the kubeconfig secret instead of injecting."

**Approach:** fork `KThreesConfig` logic, or sit a mutating admission webhook in front of it to strip the `write_files` CA entries. Then the bake-signed leaves + dynamic-cert.json stay valid — no purge, no regen, maybe no `--cluster-reset`.

Projected: **50–70s**, if combined with the other wins.

Tradeoff: upstream-drift risk, ongoing maintenance.

---

## 6. Recommendation

1. **Ship what we have now** — Phases 1–5 deliver the multi-image UX and a working pipeline. 136s is not the target, but it's not worse than legacy.
2. **If <60s becomes business-critical:** go straight to **Option B (warm VM pool)**. Everything else is smaller wins with similar effort.
3. **Don't** keep tuning the Phase 1 preserved-state approach. It's CA-injection-bound and will not break through the ~100s floor with CAPK in the picture.

---

## 7. Reproducing today's result

```bash
# one-time
./scripts/import-base-images.sh                    # ~3 min, ~900 MB download
make bake-image-preinit                            # ~7 min
make build-containerdisk-preinit                   # ~2 min
make pre-pull-preinit                              # seconds

# per run
kubectl delete cluster target-cluster --ignore-not-found --wait=true
./scripts/time-to-ready.sh                         # apply → 2/2 Ready
```

Expected: ~130–150s total to `RESULT:` line. p95 over 5 runs will take ~15 min of wall time.
