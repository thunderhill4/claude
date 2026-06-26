package handlers

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sclient "kubeui/backend/k8s"
)

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

func (p *poolState) claimAndSetBuilding() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.building {
		return false
	}
	p.building = true
	return true
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
		go buildStandby(false, false)
	case ActionRebuild:
		go buildStandby(false, true)
	case ActionNone:
		// nothing
	}
}

// runClaim hands over an existing WARM standby as the user's cluster: relabel
// CLAIMED and emit synthetic progress. Resolves in seconds (cluster already up).
func runClaim() {
	defer setCurrentOp("")
	deploy.addLog("step", "━━ Claiming pre-built standby cluster ━━")
	deploy.addLog("info", "A warm standby was ready — handing it over instead of building.")

	if err := labelTargetCluster(poolStateClaimed); err != nil {
		deploy.addLog("warn", "could not set claimed label: "+err.Error())
	}
	claimPending.Store(false)
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

// buildStandby builds the standby cluster off the user's clock. If claimAfter
// (or claimPending becomes set during the build) it labels CLAIMED, else WARM.
// predelete=true tears down any existing (degraded) cluster before applying.
func buildStandby(claimAfter bool, predelete bool) {
	if !pool.claimAndSetBuilding() {
		return
	}
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
	if predelete {
		deploy.addLog("step", "━━ Rebuilding standby — tearing down degraded cluster ━━")
		_ = runShell("kubectl delete cluster " + targetClusterName + " --ignore-not-found --timeout=120s")
	}
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
