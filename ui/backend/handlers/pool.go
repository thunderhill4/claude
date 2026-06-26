package handlers

import (
	"context"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync"
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
