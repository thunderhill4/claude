# Warm Pool — Level-1 Pre-Deployed Standby — Design Spec

**Date:** 2026-06-26
**Branch:** chore/dependency-upgrades
**Goal:** Bring target-cluster time-to-ready **under 40s** — realistically to single-digit
seconds — by pre-building one standby cluster off the user's clock and turning "Deploy"
into a near-instant *claim*.

Supersedes the recommendation in `docs/warm-pool-strategy.md` §3 with concrete,
decided design choices. Image pre-init (`:preinit`, `:warm`) does **not** move
time-to-ready (measured warm = 48.5s ≈ parallel; see `project_warm_image_path.md`). The
only remaining lever is doing the build *before* the user asks.

---

## 1. Goal & Non-Goals

**Goal**
- A user-issued Deploy resolves in single-digit seconds when a standby is hot.
- Delete tears down the cluster and a fresh standby is rebuilt in the background.
- Sits on top of the proven CAPI deploy path; worst case (no standby) degrades to
  today's on-demand build.

**Non-Goals**
- Concurrent target-clusters (single-cluster-at-a-time is assumed throughout).
- Level-2 paused VM pool / snapshot-restore (deferred; see strategy doc §2).
- Per-cluster random identity (fixed CA/token reuse is safe under single-cluster).

---

## 2. Core Invariant

**At most one `target-cluster` Cluster object exists at any moment.** The standby *is*
the cluster the user will claim. The controller builds a standby **only when no Cluster
exists**, so peak memory stays ~14Gi (never two clusters running at once).

---

## 3. State Machine

State is tracked by a label on the `Cluster` object: `pool.local/state`.
The **live Cluster object + label is the source of truth** — not in-memory state — so a
backend restart re-derives correctly.

```
   (no Cluster)
       │  controller builds via parallel :latest (~61s, background)
       ▼
     WARM ───────claim (POST /cluster/deploy)──────▶ CLAIMED
       ▲                                                │ POST /cluster/delete
       │ controller rebuilds (only after teardown)      ▼
       └─────────────── (no Cluster) ◀──────────── teardown completes
```

| State        | Meaning                                                       |
|--------------|---------------------------------------------------------------|
| (no Cluster) | Nothing deployed. Controller will build a standby.            |
| `WARM`       | Standby built, 2/2 nodes Ready, unclaimed. Ready to hand over. |
| `CLAIMED`    | User has claimed it; it is now their working cluster.         |

Transitions:
- **build → WARM**: controller applies the standby manifest, waits for 2/2 Ready, sets `pool.local/state=WARM`.
- **WARM → CLAIMED**: claim path relabels the existing cluster.
- **CLAIMED → (none)**: user Delete tears the cluster down.
- **(none) → WARM**: controller reconcile rebuilds.

---

## 4. Components

### 4.1 Pool controller (goroutine in `ui/backend`)

Started from `ui/backend/main.go` after the mux is built (e.g. `go handlers.RunPoolController(ctx)`).
Reconcile loop polls every ~5s and takes **one** action per tick:

```
reconcile():
  if !POOL_ENABLED: return
  if userOpInFlight(): return            # shared lock with deploy/delete (getCurrentOp())
  cluster := getTargetCluster()          # nil | {state, ready}
  switch:
    cluster == nil and !building:
        building = true
        go buildStandby()                # parallel :latest, full; on 2/2 Ready -> label WARM; clear building
    cluster.state == WARM and !cluster.ready:
        # health watchdog: degraded idle standby
        teardownAndRebuild()
    else: no-op                          # WARM healthy, or CLAIMED (hands off), or building
```

- `buildStandby()` reuses the existing deploy machinery (applies
  `03-target-cluster/target-cluster-parallel.yaml` via the same apply/wait helpers used
  by `runDeployment`), then patches the `pool.local/state=WARM` label once 2/2 Ready.
- Build failures: log, clear `building`, retry on a later tick with capped backoff.
- The controller writes its status to a small in-memory struct read by `pool-status`.

### 4.2 Claim path (extend `HandleDeployCluster`)

`POST /api/v1/cluster/deploy`:
1. If a `WARM` cluster exists and is Ready:
   - Relabel `pool.local/state=CLAIMED`.
   - Fetch kubeconfig (`clusterctl get kubeconfig target-cluster`), copy to the repo path
     (same as `runDeployment` Step 6).
   - Emit synthetic SSE: `step` "Claiming pre-built standby", `success` lines for
     kubeconfig + nodes Ready, then `done`. Resolves in ~3–8s.
   - Mark op done.
2. Else (no standby, or it raced away / is NotReady): fall through to the **existing**
   `runDeployment(profile, image)` — default image `warm` — streaming as today (~48.5s).

The `profile`/`image` query params keep working for the fallback live build. (A claim
returns whatever the standby was built as — full `:latest`; documented.)

### 4.3 Delete path (existing `HandleDeleteClusterStream`)

Unchanged behavior: `kubectl delete cluster target-cluster`, CAPI reaps the VMs. After
teardown completes the cluster object is gone, so the controller's next reconcile sees
`(no Cluster)` and rebuilds a standby. No explicit signal needed (reconcile is the
trigger), but the delete handler clears `currentOp` on completion so the controller is
unblocked promptly.

### 4.4 Pool status API + UI

- `GET /api/v1/cluster/pool-status` → `{ "state": "none"|"building"|"warm"|"claimed", "clusterReady": bool, "lastError": string }`.
- Route added in `main.go`; handler in `cluster_deploy.go`.
- Frontend (`ClusterManager.tsx`): poll `pool-status`; show a small non-blocking
  indicator — "⚡ Standby ready" (warm), "Building standby…" (building), nothing (none/claimed).
  No change to the Deploy button flow; it just resolves fast when warm.
- `api.ts`: add `getPoolStatus()`.

---

## 5. Concurrency & Guards

- **Single op-lock**: the controller and user ops share the existing `currentOp`
  (`setCurrentOp`/`getCurrentOp`) + a `building` flag, so we never run a standby build and
  a user deploy/delete simultaneously, and never end up with two clusters.
- **Claim race**: if the standby disappears or flips NotReady between the existence check
  and the relabel, the claim falls through to a live build (no hard failure).
- **Restart safety**: on backend start, the controller reads the live Cluster + label to
  derive state; an in-progress build that died mid-flight is detected as
  `(no Cluster)` or a NotReady WARM and is rebuilt.

---

## 6. Configuration

Env vars (set in `run-ui.sh`, defaults in code):

| Var                    | Default  | Meaning                                            |
|------------------------|----------|----------------------------------------------------|
| `POOL_ENABLED`         | `true`   | Master switch. `false` → pure on-demand (today).   |
| `POOL_STANDBY_PROFILE` | `full`   | Standby sizing (`full`=14Gi idle, `lite`=8Gi).     |
| `POOL_STANDBY_MANIFEST`| `03-target-cluster/target-cluster-parallel.yaml` | Standby build source. |
| `POOL_POLL_SECONDS`    | `5`      | Reconcile interval.                                |

The on-demand *fallback* (no standby ready) uses the existing deploy default (`warm`),
independent of the standby recipe.

---

## 7. Error Handling

- **Standby build fails** → controller logs, surfaces `state=building, lastError=...`,
  retries with capped backoff (e.g. 5s → 30s).
- **Idle standby degrades** (WARM but NotReady) → watchdog tears down + rebuilds.
- **Claim with stale standby** → fall through to live build.
- **Disabled pool** → `pool-status` returns `none`/`claimed` from the live cluster only;
  deploy/delete behave exactly as today.

---

## 8. Testing

**Unit (pure functions, table-driven):**
- `reconcileDecision(clusterExists, state, ready, opInFlight, building) → action`
  covering: none→build, WARM-healthy→noop, WARM-NotReady→rebuild, CLAIMED→noop,
  opInFlight→noop, building→noop.
- `claimDecision(warmExists, ready) → {claim | liveBuild}`.

These isolate the decision logic from kubectl/CAPI side effects so they run with no
cluster.

**Manual end-to-end (measured, recorded in the memory note):**
1. Cold start → controller builds standby → `pool-status` reaches `warm` (~61s, off-clock).
2. Claim (UI Deploy) → measure wall-clock to `done`; **target single-digit seconds, must be <40s**.
3. Delete → confirm controller rebuilds a fresh standby; second claim is instant too.
4. Idle-degradation: delete a standby node out-of-band → watchdog rebuilds.

**Acceptance gate:** step 2 measured < 40s (ideally < 10s) with a hot standby.

---

## 9. Limitations & Honest Caveats

- **Not always instant.** First deploy after a cold start, or a deploy issued before a
  post-delete rebuild finishes, still pays ~50–61s (falls back to live build).
- **Persistent idle cost.** One full cluster (~14Gi) runs whenever the UI backend is up.
  Accepted (host has ~21Gi free).
- **Standby maintained only while the backend runs** (controller is a backend goroutine).
  If the backend is down, no standby is kept warm.
- **Single-cluster assumption baked in** (fixed identity + size-1 standby). Concurrency
  would require Level-2 + per-cluster identity.
- **Claim hands over whatever the standby was built as** (full `:latest`); the UI profile
  selector only affects the fallback live build, not a claim. Documented in the UI note.

---

## 10. Out of Scope (future)

- Level-2 paused VM pool / snapshot-restore for >1 cluster or sub-second rebuilds.
- Per-cluster identity for concurrent clusters.
- Running the controller as a standalone systemd unit (so the standby survives UI
  restarts) — revisit if the backend-goroutine lifetime proves limiting.
