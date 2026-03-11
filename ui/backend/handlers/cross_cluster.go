package handlers

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ProbeResult holds the outcome of a single kubectl exec curl probe.
type ProbeResult struct {
	ID         string `json:"id"`
	From       string `json:"from"`
	To         string `json:"to"`
	URL        string `json:"url"`
	StatusCode int    `json:"statusCode"` // 0 = error/timeout
	LatencyMs  int    `json:"latencyMs"`
	Error      string `json:"error,omitempty"`
	Timestamp  string `json:"timestamp"`
	Direction  string `json:"direction"` // "local" | "cross-cluster"
}

// CrossClusterState is the full probe snapshot returned to the frontend.
type CrossClusterState struct {
	Probes         []ProbeResult `json:"probes"`
	HttpbinAlive   bool          `json:"httpbinAlive"`
	NginxAlive     bool          `json:"nginxAlive"`
	FailoverActive bool          `json:"failoverActive"`
	Timestamp      string        `json:"timestamp"`
}

// targetKubeconfigPath resolves the target-cluster kubeconfig path.
// Looks in CLAUDE_DIR first (set by run-ui.sh), then /tmp.
func targetKubeconfigPath() string {
	if dir := os.Getenv("CLAUDE_DIR"); dir != "" {
		p := filepath.Join(dir, "target-cluster-kubeconfig")
		if _, err := os.Stat(p); err == nil {
			return p
		}
	}
	return "/tmp/target-cluster-kubeconfig"
}

// runProbe executes a single kubectl exec curl probe and returns the result.
func runProbe(contextFlag, namespace, url, id, from, to, direction string) ProbeResult {
	result := ProbeResult{
		ID:        id,
		From:      from,
		To:        to,
		URL:       url,
		Timestamp: time.Now().Format(time.RFC3339),
		Direction: direction,
	}

	args := []string{
		contextFlag,
		"exec", "-n", namespace, "deploy/sleep", "--",
		"curl", "-s", "-o", "/dev/null",
		"-w", "%{http_code} %{time_total}",
		"--max-time", "5",
		url,
	}

	out, err := exec.Command("kubectl", args...).Output() //nolint:gosec
	if err != nil {
		result.StatusCode = 0
		// Trim noisy kubectl error messages to first line
		msg := err.Error()
		if lines := strings.SplitN(msg, "\n", 2); len(lines) > 0 {
			msg = lines[0]
		}
		result.Error = msg
		return result
	}

	parts := strings.Fields(strings.TrimSpace(string(out)))
	if len(parts) >= 2 {
		code, _ := strconv.Atoi(parts[0])
		result.StatusCode = code
		latencyF, _ := strconv.ParseFloat(parts[1], 64)
		result.LatencyMs = int(latencyF * 1000)
	}
	return result
}

// HandleCrossClusterProbe runs 4 live curl probes concurrently from sleep pods
// on each cluster and returns the aggregated health state.
//
// GET /api/v1/cross-cluster/probe
func HandleCrossClusterProbe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	tkc := targetKubeconfigPath()

	type spec struct {
		ctxFlag   string
		namespace string
		url       string
		id, from, to, direction string
	}

	specs := []spec{
		{
			"--context=kind-cluster1", "mc-demo",
			"http://httpbin.mc-demo:8000/status/200",
			"c1-local-httpbin", "cluster1", "httpbin (local)", "local",
		},
		{
			"--context=kind-cluster1", "mc-demo",
			"http://172.18.255.216:8000",
			"c1-cross-nginx", "cluster1", "nginx (target-cluster)", "cross-cluster",
		},
		{
			"--kubeconfig=" + tkc, "sample",
			"http://nginx.sample",
			"tc-local-nginx", "target-cluster", "nginx (local)", "local",
		},
		{
			"--kubeconfig=" + tkc, "sample",
			"http://172.18.255.200:8000/status/200",
			"tc-cross-httpbin", "target-cluster", "httpbin (cluster1)", "cross-cluster",
		},
	}

	probes := make([]ProbeResult, len(specs))
	var wg sync.WaitGroup
	for i, s := range specs {
		wg.Add(1)
		go func(idx int, sp spec) {
			defer wg.Done()
			probes[idx] = runProbe(sp.ctxFlag, sp.namespace, sp.url, sp.id, sp.from, sp.to, sp.direction)
		}(i, s)
	}
	wg.Wait()

	ok := func(p ProbeResult) bool { return p.StatusCode >= 200 && p.StatusCode < 300 }

	httpbinAlive := ok(probes[0])
	nginxAlive := ok(probes[2])
	// Failover: a local service is down but the cross-cluster path is still up
	failoverActive := (!httpbinAlive && ok(probes[1])) || (!nginxAlive && ok(probes[3]))

	state := CrossClusterState{
		Probes:         probes,
		HttpbinAlive:   httpbinAlive,
		NginxAlive:     nginxAlive,
		FailoverActive: failoverActive,
		Timestamp:      time.Now().Format(time.RFC3339),
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(state); err != nil {
		http.Error(w, fmt.Sprintf("encode error: %v", err), http.StatusInternalServerError)
	}
}

// safe name/namespace: alphanumeric, dash, underscore only.
var safeName = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)

// HandleCrossClusterScale scales a Kubernetes deployment to simulate failures
// or restorations during the demo.
//
// POST /api/v1/cross-cluster/scale
// Body: {"deployment":"httpbin","namespace":"mc-demo","cluster":"cluster1","replicas":0}
//
// cluster values: "cluster1" → kind-cluster1 context
//                 "target-cluster" → target-cluster kubeconfig
func HandleCrossClusterScale(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req struct {
		Deployment string `json:"deployment"`
		Namespace  string `json:"namespace"`
		Cluster    string `json:"cluster"`
		Replicas   int    `json:"replicas"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	// Validate inputs to prevent command injection
	if !safeName.MatchString(req.Deployment) || !safeName.MatchString(req.Namespace) || !safeName.MatchString(req.Cluster) {
		http.Error(w, "invalid characters in request", http.StatusBadRequest)
		return
	}
	if req.Replicas < 0 || req.Replicas > 10 {
		http.Error(w, "replicas must be 0-10", http.StatusBadRequest)
		return
	}

	var contextFlag string
	switch req.Cluster {
	case "cluster1":
		contextFlag = "--context=kind-cluster1"
	case "target-cluster":
		contextFlag = "--kubeconfig=" + targetKubeconfigPath()
	default:
		http.Error(w, "unknown cluster: must be cluster1 or target-cluster", http.StatusBadRequest)
		return
	}

	args := []string{
		contextFlag,
		"scale", "deploy/" + req.Deployment,
		"-n", req.Namespace,
		"--replicas=" + strconv.Itoa(req.Replicas),
	}

	out, err := exec.Command("kubectl", args...).CombinedOutput() //nolint:gosec
	if err != nil {
		http.Error(w, fmt.Sprintf("scale failed: %s\n%s", err, out), http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]interface{}{
		"ok":         true,
		"deployment": req.Deployment,
		"namespace":  req.Namespace,
		"cluster":    req.Cluster,
		"replicas":   req.Replicas,
		"output":     strings.TrimSpace(string(out)),
	})
}
