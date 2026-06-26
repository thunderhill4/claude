# Warm Pool — Level-1 Pre-Deployed Standby — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a user-issued cluster Deploy resolve in single-digit seconds (well under 40s) by keeping one pre-built standby `target-cluster` warm and turning Deploy into a near-instant *claim*.

**Architecture:** A reconcile goroutine inside the existing Go backend keeps exactly one `target-cluster` built and labeled `pool.local/state=WARM` whenever none exists. The Deploy handler claims a WARM cluster (relabel `CLAIMED` + synthetic SSE) instead of building; Delete tears down and the controller rebuilds. The live Cluster object + its label are the source of truth, so a backend restart re-derives state. Worst case (no standby) degrades to today's on-demand build.

**Tech Stack:** Go 1.25 stdlib `net/http`, `k8s.io/client-go` dynamic client, `kubectl`/`clusterctl` shell-outs (existing pattern), React 19 + TypeScript frontend.

## Global Constraints

- Single-cluster-at-a-time: **at most one `target-cluster` Cluster object may exist at any moment.** Never start a standby build while a cluster (WARM or CLAIMED) exists or a user op is in flight.
- Backend module is `kubeui/backend`, Go 1.25; stdlib `net/http` only (no web framework).
- Reuse existing helpers in `ui/backend/handlers/cluster_deploy.go`: `deploy` manager (`addLog`/`finish`/`resetForNewRun`/`getState`), `setCurrentOp`/`getCurrentOp`, `runShell`, `shellCheck`, `kubectlGet`, `applyStdin`, `claudeDir`, `streamDeployLogs`, `writeJSON`, `k8sclient.DynamicClient`, `capiClusterGVR`.
- Label key is exactly `pool.local/state`; values exactly `WARM` and `CLAIMED` (uppercase).
- Config env vars (read in code, defaults baked): `POOL_ENABLED` (default `true`), `POOL_STANDBY_PROFILE` (default `full`), `POOL_STANDBY_MANIFEST` (default `03-target-cluster/target-cluster-parallel.yaml`), `POOL_POLL_SECONDS` (default `5`).
- Standby is built via the parallel `:latest` path; the on-demand fallback (no standby) uses the existing deploy default (`warm`).
- Acceptance gate: a claim against a hot standby measures **< 40s** end-to-end (target < 10s).
- Run `cd ui/backend && go build ./...` and `go test ./...` after every backend task; `cd ui/frontend && npx tsc --noEmit` after every frontend task.

---

### Task 1: Pure decision functions (reconcile + claim)

The two decisions that drive the controller and the claim handler, isolated as pure functions so they are testable with no cluster.

**Files:**
- Create: `ui/backend/handlers/pool.go`
- Test: `ui/backend/handlers/pool_test.go`

**Interfaces:**
- Produces:
  - `type PoolAction int` with consts `ActionNone`, `ActionBuild`, `ActionRebuild`.
  - `func reconcileDecision(clusterExists bool, state string, ready bool, opInFlight bool, building bool) PoolAction`
  - `type ClaimAction int` with consts `ClaimLiveBuild`, `ClaimStandby`.
  - `func claimDecision(warmExists bool, ready bool) ClaimAction`
  - consts `poolStateLabel = "pool.local/state"`, `poolStateWarm = "WARM"`, `poolStateClaimed = "CLAIMED"`.

- [ ] **Step 1: Write the failing tests**

Create `ui/backend/handlers/pool_test.go`:

```go
package handlers

import "testing"

func TestReconcileDecision(t *testing.T) {
	cases := []struct {
		name         string
		clusterExists bool
		state        string
		ready        bool
		opInFlight   bool
		building     bool
		want         PoolAction
	}{
		{"no cluster idle -> build", false, "", false, false, false, ActionBuild},
		{"no cluster but op in flight -> none", false, "", false, true, false, ActionNone},
		{"no cluster but already building -> none", false, "", false, false, true, ActionNone},
		{"warm healthy -> none", true, poolStateWarm, true, false, false, ActionNone},
		{"warm not ready -> rebuild", true, poolStateWarm, false, false, false, ActionRebuild},
		{"warm not ready but op in flight -> none", true, poolStateWarm, false, true, false, ActionNone},
		{"claimed -> none", true, poolStateClaimed, true, false, false, ActionNone},
		{"claimed not ready -> none", true, poolStateClaimed, false, false, false, ActionNone},
		{"unlabeled existing cluster -> none", true, "", true, false, false, ActionNone},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := reconcileDecision(c.clusterExists, c.state, c.ready, c.opInFlight, c.building)
			if got != c.want {
				t.Fatalf("reconcileDecision(%v) = %v, want %v", c.name, got, c.want)
			}
		})
	}
}

func TestClaimDecision(t *testing.T) {
	if claimDecision(true, true) != ClaimStandby {
		t.Fatal("warm+ready should claim standby")
	}
	if claimDecision(true, false) != ClaimLiveBuild {
		t.Fatal("warm-but-not-ready should live build")
	}
	if claimDecision(false, false) != ClaimLiveBuild {
		t.Fatal("no standby should live build")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ui/backend && go test ./handlers/ -run 'TestReconcileDecision|TestClaimDecision' -v`
Expected: FAIL — `undefined: reconcileDecision` / `undefined: PoolAction`.

- [ ] **Step 3: Write minimal implementation**

Create `ui/backend/handlers/pool.go`:

```go
package handlers

// Pool state machine label + values on the target Cluster object.
const (
	poolStateLabel   = "pool.local/state"
	poolStateWarm    = "WARM"
	poolStateClaimed = "CLAIMED"
)

// PoolAction is the controller's per-tick decision.
type PoolAction int

const (
	ActionNone PoolAction = iota
	ActionBuild
	ActionRebuild
)

// reconcileDecision is the controller's pure decision: given the observed
// cluster + in-flight flags, what should happen this tick. Honors the
// single-cluster invariant — never builds while any cluster or op exists.
func reconcileDecision(clusterExists bool, state string, ready bool, opInFlight bool, building bool) PoolAction {
	if opInFlight || building {
		return ActionNone
	}
	if !clusterExists {
		return ActionBuild
	}
	if state == poolStateWarm && !ready {
		return ActionRebuild
	}
	return ActionNone
}

// ClaimAction is the deploy handler's pure decision.
type ClaimAction int

const (
	ClaimLiveBuild ClaimAction = iota
	ClaimStandby
)

// claimDecision: claim the standby only if a WARM cluster exists AND is ready.
func claimDecision(warmExists bool, ready bool) ClaimAction {
	if warmExists && ready {
		return ClaimStandby
	}
	return ClaimLiveBuild
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ui/backend && go test ./handlers/ -run 'TestReconcileDecision|TestClaimDecision' -v`
Expected: PASS (all subtests).

- [ ] **Step 5: Commit**

```bash
git add ui/backend/handlers/pool.go ui/backend/handlers/pool_test.go
git commit -m "feat(pool): pure reconcile + claim decision functions"
```

---

### Task 2: Pool state observation + status + label helpers

I/O helpers that read the live cluster's pool state and readiness, write the label, and expose `GET /api/v1/cluster/pool-status`.

**Files:**
- Modify: `ui/backend/handlers/pool.go`
- Modify: `ui/backend/main.go` (register route)
- Test: `ui/backend/handlers/pool_test.go`

**Interfaces:**
- Consumes: `poolStateLabel`, `poolStateWarm` (Task 1); `k8sclient.DynamicClient`, `capiClusterGVR`, `targetClusterName`, `kubectlGet`, `runShell`, `writeJSON`, `writeError` (existing).
- Produces:
  - `type PoolStatus struct { State string `json:"state"`; ClusterReady bool `json:"clusterReady"`; LastError string `json:"lastError"` }`
  - `func observeCluster(ctx context.Context) (exists bool, state string, ready bool)`
  - `func targetNodesReady(expected int) bool`
  - `func labelTargetCluster(state string) error`
  - global `var pool = &poolState{ ... }` with `setBuildState(s, errMsg string)`, `snapshot() PoolStatus`, `setBuilding(bool)`, `isBuilding() bool`.
  - `func HandlePoolStatus(w http.ResponseWriter, r *http.Request)`

- [ ] **Step 1: Write the failing test**

Append to `ui/backend/handlers/pool_test.go`:

```go
func TestPoolSnapshotDefault(t *testing.T) {
	p := &poolState{state: "none"}
	s := p.snapshot()
	if s.State != "none" || s.ClusterReady || s.LastError != "" {
		t.Fatalf("unexpected default snapshot: %+v", s)
	}
}

func TestPoolSetBuildState(t *testing.T) {
	p := &poolState{state: "none"}
	p.setBuildState("warm", "")
	if s := p.snapshot(); s.State != "warm" || s.LastError != "" {
		t.Fatalf("after warm: %+v", s)
	}
	p.setBuildState("building", "boom")
	if s := p.snapshot(); s.State != "building" || s.LastError != "boom" {
		t.Fatalf("after error: %+v", s)
	}
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ui/backend && go test ./handlers/ -run 'TestPool' -v`
Expected: FAIL — `undefined: poolState`.

- [ ] **Step 3: Write the implementation**

Append to `ui/backend/handlers/pool.go` (add imports `context`, `net/http`, `os`, `strconv`, `strings`, `sync`, `time`, `metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"`, `k8sclient "kubeui/backend/k8s"`):

```go
// PoolStatus is the JSON shape returned by GET /api/v1/cluster/pool-status.
type PoolStatus struct {
	State        string `json:"state"` // none | building | warm | claimed
	ClusterReady bool   `json:"clusterReady"`
	LastError    string `json:"lastError"`
}

// poolState is the controller's in-memory view, surfaced via pool-status.
// The live Cluster object remains the source of truth; this is a cache for UI.
type poolState struct {
	mu       sync.Mutex
	state    string // none | building | warm | claimed
	ready    bool
	lastErr  string
	building bool
}

var pool = &poolState{state: "none"}

func (p *poolState) setBuildState(state, errMsg string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.state = state
	p.lastErr = errMsg
}

func (p *poolState) setReady(ready bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.ready = ready
}

func (p *poolState) setBuilding(b bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.building = b
}

func (p *poolState) isBuilding() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.building
}

func (p *poolState) snapshot() PoolStatus {
	p.mu.Lock()
	defer p.mu.Unlock()
	return PoolStatus{State: p.state, ClusterReady: p.ready, LastError: p.lastErr}
}

// observeCluster reads the live target Cluster: whether it exists, its
// pool.local/state label, and whether 2 nodes are Ready.
func observeCluster(ctx context.Context) (exists bool, state string, ready bool) {
	obj, err := k8sclient.DynamicClient.Resource(capiClusterGVR).Namespace("default").Get(ctx, targetClusterName, metav1.GetOptions{})
	if err != nil {
		return false, "", false
	}
	state = obj.GetLabels()[poolStateLabel]
	ready = targetNodesReady(2)
	return true, state, ready
}

// targetNodesReady reports whether >= expected nodes are Ready on the target
// cluster (via its kubeconfig at /tmp/<name>-kubeconfig).
func targetNodesReady(expected int) bool {
	kubeconfig := "/tmp/" + targetClusterName + "-kubeconfig"
	if _, err := os.Stat(kubeconfig); err != nil {
		return false
	}
	out := kubectlGet("--kubeconfig="+kubeconfig, "get", "nodes",
		"-o", "jsonpath={range .items[*]}{.status.conditions[?(@.type==\"Ready\")].status}{\"\\n\"}{end}")
	ready := 0
	for _, line := range strings.Split(out, "\n") {
		if strings.TrimSpace(line) == "True" {
			ready++
		}
	}
	return ready >= expected
}

// labelTargetCluster sets pool.local/state=<state> on the target Cluster.
func labelTargetCluster(state string) error {
	return runShell("kubectl label cluster " + targetClusterName +
		" " + poolStateLabel + "=" + state + " --overwrite")
}

func poolPollInterval() time.Duration {
	if v := os.Getenv("POOL_POLL_SECONDS"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return time.Duration(n) * time.Second
		}
	}
	return 5 * time.Second
}

func poolEnabled() bool { return os.Getenv("POOL_ENABLED") != "false" }

// HandlePoolStatus: GET /api/v1/cluster/pool-status
func HandlePoolStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	writeJSON(w, pool.snapshot())
}
```

- [ ] **Step 4: Register the route**

In `ui/backend/main.go`, after the line registering `/api/v1/cluster/target-status` (`mux.HandleFunc("/api/v1/cluster/target-status", handlers.HandleTargetClusterStatus)`), add:

```go
	mux.HandleFunc("/api/v1/cluster/pool-status", handlers.HandlePoolStatus)
```

- [ ] **Step 5: Run tests + build**

Run: `cd ui/backend && go test ./handlers/ -run 'TestPool' -v && go build ./...`
Expected: PASS and clean build.

- [ ] **Step 6: Commit**

```bash
git add ui/backend/handlers/pool.go ui/backend/main.go ui/backend/handlers/pool_test.go
git commit -m "feat(pool): cluster observation, label + status endpoint"
```

---

### Task 3: Standby build + reconcile controller goroutine

The reconcile loop and the background standby build. Reuses the proven deploy wait-logic by extracting it from `runDeployment`.

**Files:**
- Modify: `ui/backend/handlers/cluster_deploy.go` (extract a reusable wait helper)
- Modify: `ui/backend/handlers/pool.go` (controller + build)
- Modify: `ui/backend/main.go` (start goroutine)

**Interfaces:**
- Consumes: `deploy` manager, `setCurrentOp`/`getCurrentOp`, `applyStdin`, `claudeDir`, `runShell`, `reconcileDecision`, `observeCluster`, `labelTargetCluster`, `targetNodesReady`, `pool` (Tasks 1–2).
- Produces:
  - `func waitForTargetReady(expectedVMs int) error` (extracted; waits VMs → kubeconfig → API → nodes Ready, streaming to `deploy`).
  - `func RunPoolController(ctx context.Context)`
  - `func buildStandby(claimAfter bool)`
  - global `var claimPending atomic.Bool`

- [ ] **Step 1: Extract the wait helper from runDeployment**

In `ui/backend/handlers/cluster_deploy.go`, the body of `runDeployment` Steps 5 and 6 (the VM-wait loop, kubeconfig fetch, API-wait, and nodes-Ready loop — from `// ── Step 5: Wait for VMs ──` through the nodes-Ready loop, ending just before `deploy.addLog("step", "━━ Done! ━━")`) is moved verbatim into a new function. Add this function (it streams via the existing `deploy` manager and returns an error instead of calling `fail`):

```go
// waitForTargetReady waits for VMs to boot, fetches the kubeconfig, and waits
// for the API server + nodes to be Ready. Streams progress to the deploy log.
// Returns an error (so callers decide how to fail) instead of finishing.
func waitForTargetReady(expectedVMs int) error {
	dir := claudeDir()

	deploy.addLog("step", "━━ Wait for VMs to Boot ━━")
	vmTimeout := time.Now().Add(20 * time.Minute)
	for {
		if time.Now().After(vmTimeout) {
			return fmt.Errorf("timed out waiting for VMs after 20 minutes")
		}
		vmiLines := kubectlGet("get", "vmi",
			"-l", "cluster.x-k8s.io/cluster-name="+targetClusterName,
			"-o", "jsonpath={range .items[*]}{.metadata.name}={.status.phase}{\"\\n\"}{end}")
		running, total := 0, 0
		for _, line := range strings.Split(vmiLines, "\n") {
			if strings.TrimSpace(line) == "" {
				continue
			}
			total++
			if strings.HasSuffix(line, "=Running") {
				running++
			}
		}
		deploy.addLog("info", fmt.Sprintf("  VMIs: %d/%d Running", running, total))
		if running >= expectedVMs {
			break
		}
		time.Sleep(15 * time.Second)
	}
	deploy.addLog("success", "✓ VMs are running")

	deploy.addLog("step", "━━ Wait for Target API Server ━━")
	kubeconfigPath := "/tmp/" + targetClusterName + "-kubeconfig"
	kubeconfigLocal := filepath.Join(dir, targetClusterName+"-kubeconfig")
	kcTimeout := time.Now().Add(3 * time.Minute)
	gotKC := false
	for time.Now().Before(kcTimeout) {
		if err := runShell(fmt.Sprintf("clusterctl get kubeconfig %s > %s 2>/dev/null", targetClusterName, kubeconfigPath)); err == nil {
			runShell(fmt.Sprintf("cp %s %s 2>/dev/null || true", kubeconfigPath, kubeconfigLocal))
			deploy.addLog("success", "✓ Kubeconfig retrieved → "+kubeconfigPath)
			gotKC = true
			break
		}
		time.Sleep(10 * time.Second)
	}
	if !gotKC {
		return fmt.Errorf("could not retrieve kubeconfig after 3 minutes")
	}

	apiTimeout := time.Now().Add(5 * time.Minute)
	for {
		if shellCheck(fmt.Sprintf("kubectl --kubeconfig=%s get nodes --request-timeout=5s 2>/dev/null", kubeconfigPath)) {
			deploy.addLog("success", "✓ API server is responding")
			break
		}
		if time.Now().After(apiTimeout) {
			return fmt.Errorf("API server not reachable after 5 minutes")
		}
		time.Sleep(10 * time.Second)
	}

	nodesTimeout := time.Now().Add(3 * time.Minute)
	for {
		if targetNodesReady(2) {
			deploy.addLog("success", "✓ All nodes are Ready")
			break
		}
		if time.Now().After(nodesTimeout) {
			deploy.addLog("warn", "Nodes not all Ready yet — continuing")
			break
		}
		time.Sleep(15 * time.Second)
	}
	return nil
}
```

Then in `runDeployment`, replace the deleted Steps 5–6 block with:

```go
	if err := waitForTargetReady(expectedVMs); err != nil {
		fail(err.Error())
		return
	}
```

(Keep the existing `const expectedVMs = 2` near the call, and keep the final `deploy.addLog("step", "━━ Done! ━━")` … `deploy.finish("done")` block. Add this label step right before the Done block so a user live-build is recorded as claimed:)

```go
	_ = labelTargetCluster(poolStateClaimed)
```

- [ ] **Step 2: Verify the refactor still builds + existing behavior intact**

Run: `cd ui/backend && go build ./... && go vet ./handlers/`
Expected: clean build, no vet errors.

- [ ] **Step 3: Write the controller + standby build**

Append to `ui/backend/handlers/pool.go` (add imports `context`, `path/filepath`, `sync/atomic`, `time`, `fmt`, `os`):

```go
// claimPending is set when a user claims while a standby build is in flight, so
// the build labels the cluster CLAIMED (not WARM) when it completes.
var claimPending atomic.Bool

// RunPoolController is the reconcile loop. Start once from main() in a goroutine.
func RunPoolController(ctx context.Context) {
	if !poolEnabled() {
		pool.setBuildState("none", "")
		return
	}
	ticker := time.NewTicker(poolPollInterval())
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			poolReconcileTick(ctx)
		}
	}
}

func poolReconcileTick(ctx context.Context) {
	exists, state, ready := observeCluster(ctx)
	// Refresh the UI cache from observed truth (unless mid-build).
	if !pool.isBuilding() {
		switch {
		case !exists:
			pool.setBuildState("none", "")
		case state == poolStateClaimed:
			pool.setBuildState("claimed", "")
		case state == poolStateWarm:
			pool.setBuildState("warm", "")
		}
		pool.setReady(ready)
	}

	opInFlight := getCurrentOp() != ""
	switch reconcileDecision(exists, state, ready, opInFlight, pool.isBuilding()) {
	case ActionBuild:
		go buildStandby(false)
	case ActionRebuild:
		go func() {
			_ = runShell("kubectl delete cluster " + targetClusterName + " --ignore-not-found --timeout=120s")
			buildStandby(false)
		}()
	case ActionNone:
		// nothing
	}
}

// buildStandby builds the standby cluster off the user's clock. If claimAfter
// (or claimPending becomes set during the build) it labels CLAIMED, else WARM.
func buildStandby(claimAfter bool) {
	if pool.isBuilding() {
		return
	}
	pool.setBuilding(true)
	setCurrentOp("pool-build")
	defer func() {
		setCurrentOp("")
		pool.setBuilding(false)
		if r := recover(); r != nil {
			pool.setBuildState("none", fmt.Sprintf("panic: %v", r))
		}
	}()

	deploy.resetForNewRun()
	pool.setBuildState("building", "")
	deploy.addLog("step", "━━ Building warm standby cluster (background) ━━")

	manifest := os.Getenv("POOL_STANDBY_MANIFEST")
	if manifest == "" {
		manifest = "03-target-cluster/target-cluster-parallel.yaml"
	}
	manifestPath := filepath.Join(claudeDir(), manifest)
	if err := runShell("kubectl apply -f " + manifestPath); err != nil {
		pool.setBuildState("none", "apply failed: "+err.Error())
		deploy.finish("failed")
		return
	}
	if err := waitForTargetReady(2); err != nil {
		pool.setBuildState("none", err.Error())
		deploy.finish("failed")
		return
	}

	label := poolStateWarm
	uiState := "warm"
	if claimAfter || claimPending.Load() {
		label = poolStateClaimed
		uiState = "claimed"
		claimPending.Store(false)
	}
	if err := labelTargetCluster(label); err != nil {
		deploy.addLog("warn", "could not set pool label: "+err.Error())
	}
	pool.setReady(true)
	pool.setBuildState(uiState, "")
	if uiState == "warm" {
		deploy.addLog("success", "✓ Warm standby ready — Deploy will claim it instantly")
	} else {
		deploy.addLog("success", "✓ Cluster ready")
	}
	deploy.finish("done")
}
```

- [ ] **Step 4: Start the controller in main**

In `ui/backend/main.go`, add `"context"` to imports. Immediately before `mux := http.NewServeMux()` add:

```go
	// Pool controller: keep one warm standby cluster pre-built.
	go handlers.RunPoolController(context.Background())
```

- [ ] **Step 5: Build + test**

Run: `cd ui/backend && go build ./... && go test ./handlers/ -run 'TestReconcile|TestClaim|TestPool' -v`
Expected: clean build, all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add ui/backend/handlers/pool.go ui/backend/handlers/cluster_deploy.go ui/backend/main.go
git commit -m "feat(pool): reconcile controller + background standby build"
```

---

### Task 4: Claim path in the Deploy handler

Make Deploy claim a hot standby instantly; otherwise attach to an in-flight build or fall back to a live build.

**Files:**
- Modify: `ui/backend/handlers/cluster_deploy.go` (`HandleDeployCluster`)
- Modify: `ui/backend/handlers/pool.go` (add `runClaim`)

**Interfaces:**
- Consumes: `claimDecision`, `observeCluster`, `labelTargetCluster`, `pool`, `claimPending`, `deploy`, `setCurrentOp`, `streamDeployLogs`, `runShell`, `claudeDir` (existing/prior tasks).
- Produces: `func runClaim()`.

- [ ] **Step 1: Add the claim runner**

Append to `ui/backend/handlers/pool.go`:

```go
// runClaim hands over an existing WARM standby as the user's cluster: relabel
// CLAIMED and emit synthetic progress. Resolves in seconds (cluster already up).
func runClaim() {
	defer setCurrentOp("")
	deploy.resetForNewRun()
	deploy.addLog("step", "━━ Claiming pre-built standby cluster ━━")
	deploy.addLog("info", "A warm standby was ready — handing it over instead of building.")

	if err := labelTargetCluster(poolStateClaimed); err != nil {
		deploy.addLog("warn", "could not set claimed label: "+err.Error())
	}
	// Refresh the local kubeconfig copy for downstream scripts (istio, verify).
	kubeconfigPath := "/tmp/" + targetClusterName + "-kubeconfig"
	kubeconfigLocal := filepath.Join(claudeDir(), targetClusterName+"-kubeconfig")
	_ = runShell(fmt.Sprintf("clusterctl get kubeconfig %s > %s 2>/dev/null && cp %s %s 2>/dev/null || true",
		targetClusterName, kubeconfigPath, kubeconfigPath, kubeconfigLocal))

	pool.setBuildState("claimed", "")
	pool.setReady(true)
	deploy.addLog("success", "✓ Kubeconfig ready → "+kubeconfigPath)
	deploy.addLog("success", "✓ Standby claimed — cluster is up and Ready")
	deploy.addLog("step", "━━ Done! ━━")
	deploy.finish("done")
}
```

- [ ] **Step 2: Wire the claim decision into HandleDeployCluster**

In `ui/backend/handlers/cluster_deploy.go`, replace the body of the `if state != "running"` block in `HandleDeployCluster` (the block that currently parses `profile`/`image`, calls `resetForNewRun`, `setCurrentOp("deploy")`, `go runDeployment(...)`) with:

```go
	state := deploy.getState()
	if state != "running" {
		profile := r.URL.Query().Get("profile")
		if _, ok := profileSpecs[profile]; !ok {
			profile = "full"
		}
		image := r.URL.Query().Get("image")
		if _, ok := imageVariants[image]; !ok {
			image = warmImageKey
		}

		// Fast path: claim a hot standby if one exists and is Ready.
		exists, plState, ready := observeCluster(r.Context())
		warm := exists && plState == poolStateWarm
		if claimDecision(warm, ready) == ClaimStandby {
			setCurrentOp("deploy")
			go runClaim()
		} else {
			setCurrentOp("deploy")
			go runDeployment(profile, image)
		}
	}

	streamDeployLogs(w, r)
```

Note: a deploy issued *while the controller is mid-build* hits the `state == "running"` branch (the build runs through the same `deploy` manager), so it simply attaches to the live build stream. Set `claimPending` so that build labels CLAIMED. Add — at the very top of `HandleDeployCluster`, after the method check:

```go
	if deploy.getState() == "running" && getCurrentOp() == "pool-build" {
		claimPending.Store(true)
	}
```

- [ ] **Step 3: Build**

Run: `cd ui/backend && go build ./... && go test ./handlers/ -v`
Expected: clean build, all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add ui/backend/handlers/pool.go ui/backend/handlers/cluster_deploy.go
git commit -m "feat(pool): claim hot standby from the deploy handler"
```

---

### Task 5: Frontend standby indicator

Show pool state on the Deploy panel; no change to the Deploy button flow.

**Files:**
- Modify: `ui/frontend/src/lib/types.ts` (add `PoolStatus`)
- Modify: `ui/frontend/src/lib/api.ts` (add `getPoolStatus`)
- Modify: `ui/frontend/src/components/sre/ClusterManager.tsx` (poll + indicator)

**Interfaces:**
- Consumes: backend `GET /api/v1/cluster/pool-status` → `{ state, clusterReady, lastError }`.
- Produces: `api.getPoolStatus(): Promise<PoolStatus>`; `PoolStatus` type.

- [ ] **Step 1: Add the type**

In `ui/frontend/src/lib/types.ts`, add:

```ts
export interface PoolStatus {
  state: 'none' | 'building' | 'warm' | 'claimed';
  clusterReady: boolean;
  lastError: string;
}
```

- [ ] **Step 2: Add the API call**

In `ui/frontend/src/lib/api.ts`, add `PoolStatus` to the type import from `./types`, and add this method to the `api` object (next to `getRegistryImages`):

```ts
  getPoolStatus: () => fetchJSON<PoolStatus>(`${BASE}/cluster/pool-status`),
```

- [ ] **Step 3: Poll + render the indicator**

In `ui/frontend/src/components/sre/ClusterManager.tsx`:

Add state near the other `useState` hooks:

```tsx
  const [poolStatus, setPoolStatus] = useState<'none' | 'building' | 'warm' | 'claimed'>('none');
```

Add a polling effect (place with the other effects):

```tsx
  useEffect(() => {
    let alive = true;
    const poll = async () => {
      try {
        const s = await api.getPoolStatus();
        if (alive) setPoolStatus(s.state);
      } catch { /* ignore */ }
    };
    poll();
    const id = setInterval(poll, 5000);
    return () => { alive = false; clearInterval(id); };
  }, []);
```

Render a badge just above the Profile selector block (the `{/* ── Profile selector ── */}` comment):

```tsx
      {poolStatus === 'warm' && (
        <div className="flex items-center gap-2 text-xs text-green-600">
          <span>⚡ Standby ready — Deploy claims instantly</span>
        </div>
      )}
      {poolStatus === 'building' && (
        <div className="flex items-center gap-2 text-xs text-muted-foreground">
          <span>Building standby… next Deploy will be instant once ready</span>
        </div>
      )}
```

Ensure `useEffect` is imported from `react` (add to the existing React import if missing).

- [ ] **Step 4: Typecheck**

Run: `cd ui/frontend && npx tsc --noEmit`
Expected: no output (passes).

- [ ] **Step 5: Commit**

```bash
git add ui/frontend/src/lib/types.ts ui/frontend/src/lib/api.ts ui/frontend/src/components/sre/ClusterManager.tsx
git commit -m "feat(pool): standby-ready indicator on the deploy panel"
```

---

### Task 6: Config + docs

Document the pool, set defaults in `run-ui.sh`, update CLAUDE.md.

**Files:**
- Modify: `run-ui.sh`
- Modify: `CLAUDE.md`

**Interfaces:** none (config/docs only).

- [ ] **Step 1: Add env defaults to run-ui.sh**

In `run-ui.sh`, with the other exported env vars (near the `SYMPOZIUM_*` exports), add:

```bash
export POOL_ENABLED="${POOL_ENABLED:-true}"
export POOL_STANDBY_PROFILE="${POOL_STANDBY_PROFILE:-full}"
export POOL_STANDBY_MANIFEST="${POOL_STANDBY_MANIFEST:-03-target-cluster/target-cluster-parallel.yaml}"
export POOL_POLL_SECONDS="${POOL_POLL_SECONDS:-5}"
```

- [ ] **Step 2: Document in CLAUDE.md**

In `CLAUDE.md`, under "Web UI Architecture" → after the "AI Integration" subsection (or near the cluster-deploy routes table), add a short subsection:

```markdown
### Warm Pool (pre-deployed standby)

The backend keeps one `target-cluster` pre-built and labeled `pool.local/state=WARM`
(reconcile goroutine in `ui/backend/handlers/pool.go`). Deploy **claims** a warm standby
(relabel `CLAIMED`, synthetic SSE) in seconds instead of building (~50s). Delete tears
down and the controller rebuilds a standby in the background. Invariant: at most one
`target-cluster` at a time. Endpoint: `GET /api/v1/cluster/pool-status`
→ `{state: none|building|warm|claimed, clusterReady, lastError}`. Disable with
`POOL_ENABLED=false`. Standby builds via `target-cluster-parallel.yaml` (`:latest`);
the on-demand fallback uses the warm image. Demo-only (fixed CA/token, single cluster).
```

- [ ] **Step 3: Commit**

```bash
git add run-ui.sh CLAUDE.md
git commit -m "docs(pool): config defaults + CLAUDE.md warm-pool section"
```

---

### Task 7: End-to-end measurement + acceptance gate

Prove the claim path beats 40s and the rebuild cycle works. Manual — exercises real CAPI/VMs.

**Files:** none (verification only; record result in the memory note).

- [ ] **Step 1: Start the backend with the pool enabled**

Run: `make ui` (or `cd ui/backend && CLAUDE_DIR=$(git rev-parse --show-toplevel) POOL_ENABLED=true go run .`)
Ensure no `target-cluster` exists first: `kubectl get cluster -A` → "No resources found".

- [ ] **Step 2: Watch the standby build to WARM**

Run: `watch -n2 'curl -s localhost:8080/api/v1/cluster/pool-status; echo; kubectl get cluster target-cluster -o jsonpath="{.metadata.labels.pool\.local/state}" 2>/dev/null'`
Expected: `state` goes `building` → `warm`, label becomes `WARM`, within ~60–70s. Confirm 2 nodes Ready: `kubectl get cluster` and the target kubeconfig.

- [ ] **Step 3: Measure a claim**

Run:
```bash
START=$(date +%s%N); \
curl -sN -X POST localhost:8080/api/v1/cluster/deploy | grep -m1 '"message":"done"' >/dev/null; \
END=$(date +%s%N); echo "claim: $(( (END-START)/1000000 )) ms"
```
Expected: **< 40000 ms (target < 10000 ms).** Label flips to `CLAIMED`.

- [ ] **Step 4: Verify delete → rebuild**

Run: `curl -sN -X POST localhost:8080/api/v1/cluster/delete | tail -3`
Then re-watch `pool-status`: after teardown the controller rebuilds a fresh standby (`building` → `warm`). A second claim is instant again.

- [ ] **Step 5: Record the result**

Append the measured claim time to the memory note `project_warm_image_path.md` (or a new `project-warm-pool.md`): claim ms, build-to-warm seconds, host RAM headroom. If the claim missed 40s, file a follow-up rather than marking the gate passed.

- [ ] **Step 6: Final cleanup commit (if any tuning was needed)**

```bash
git add -A && git commit -m "test(pool): record end-to-end claim measurement"
```

---

## Self-Review Notes

- **Spec coverage:** invariant (Global Constraints, Task 3 reconcile), state machine label (Tasks 1–3), controller goroutine (Task 3), claim path + fallback + attach-to-build (Task 4), delete→rebuild (Task 3 reconcile on `(none)`), pool-status API + UI indicator (Tasks 2, 5), config env (Task 6), unit tests for decisions (Tasks 1–2), E2E acceptance <40s (Task 7), error handling (build failure → `setBuildState("none", err)` + retry next tick; degraded WARM → `ActionRebuild`; claim race → `claimDecision` falls to live build; restart safety → `observeCluster` re-derives). All covered.
- **Type consistency:** `PoolAction`/`ClaimAction` consts, `poolState`/`PoolStatus`, `reconcileDecision`/`claimDecision`, `observeCluster`/`targetNodesReady`/`labelTargetCluster`, `buildStandby`/`runClaim`/`RunPoolController`/`waitForTargetReady` used consistently across tasks.
- **No placeholders:** all steps contain concrete code/commands.
