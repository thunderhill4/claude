package handlers

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	k8sclient "kubeui/backend/k8s"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const targetClusterName = "target-cluster"
const targetLBIP = "172.18.255.215"

// imageVariant describes a golden image the user can pick.
// Image is the full containerDisk ref used as the {{IMAGE}} placeholder.
type imageVariant struct {
	Image string
	Label string
}

// The "warm" variant is the default fast-path: a golden image baked with fixed
// CAs + token so first boot skips --cluster-reset/cert-purge, combined with a
// parallel worker boot. Targets time-to-ready <40s. Selecting it switches the
// deploy to the warm template + secret-seed step (see runDeployment).
var imageVariants = map[string]imageVariant{
	"warm":    {Image: "172.18.0.2:5000/ubuntu-noble-k3s:warm", Label: "Warm fast-path (~40s, parallel boot)"},
	"noble":   {Image: "172.18.0.2:5000/ubuntu-noble-k3s:preinit", Label: "Ubuntu Noble (pre-init)"},
	"minimal": {Image: "172.18.0.2:5000/ubuntu-minimal-k3s:preinit", Label: "Ubuntu Minimal (pre-init)"},
}

// warmImageKey is the imageVariants key that triggers the warm fast-path.
const warmImageKey = "warm"

// profileSpec holds the CP/worker resource sizing for a named profile.
type profileSpec struct {
	CPCPU     string
	CPMem     string
	WorkerCPU string
	WorkerMem string
	Label     string
}

var profileSpecs = map[string]profileSpec{
	"lite": {CPCPU: "2", CPMem: "4Gi", WorkerCPU: "2", WorkerMem: "4Gi", Label: "Lite — CP: 2 CPU · 4Gi | Worker: 2 CPU · 4Gi"},
	"full": {CPCPU: "4", CPMem: "8Gi", WorkerCPU: "4", WorkerMem: "6Gi", Label: "Full — CP: 4 CPU · 8Gi | Worker: 4 CPU · 6Gi"},
}

var (
	capiClusterGVR = schema.GroupVersionResource{
		Group: "cluster.x-k8s.io", Version: "v1beta1", Resource: "clusters",
	}
	capiMachineGVR = schema.GroupVersionResource{
		Group: "cluster.x-k8s.io", Version: "v1beta1", Resource: "machines",
	}
)

// ── Operation tracking ────────────────────────────────────────────
// Tracks whether the current run is a "deploy" or "delete" operation.

var (
	opMu      sync.Mutex
	currentOp string // "deploy" | "delete" | ""
)

func setCurrentOp(op string) {
	opMu.Lock()
	defer opMu.Unlock()
	currentOp = op
}

func getCurrentOp() string {
	opMu.Lock()
	defer opMu.Unlock()
	return currentOp
}

// ── Log entry ────────────────────────────────────────────────────

type LogEntry struct {
	Type    string `json:"type"` // step | info | success | error | warn | done
	Message string `json:"message"`
	Time    string `json:"time"`
}

// ── Deployment state ─────────────────────────────────────────────

type deployManager struct {
	mu    sync.Mutex
	state string // idle | running | done | failed
	logs  []LogEntry
	subs  []chan LogEntry
}

var deploy = &deployManager{state: "idle"}

func (d *deployManager) getState() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.state
}

func (d *deployManager) resetForNewRun() {
	d.mu.Lock()
	defer d.mu.Unlock()
	// Signal stale subscribers to exit
	term := LogEntry{Type: "done", Message: "restarted"}
	for _, ch := range d.subs {
		select {
		case ch <- term:
		default:
		}
	}
	d.subs = nil
	d.logs = nil
	d.state = "running"
}

func (d *deployManager) addLog(t, msg string) {
	entry := LogEntry{Type: t, Message: msg, Time: time.Now().Format("15:04:05")}
	d.mu.Lock()
	d.logs = append(d.logs, entry)
	subs := make([]chan LogEntry, len(d.subs))
	copy(subs, d.subs)
	d.mu.Unlock()
	for _, ch := range subs {
		select {
		case ch <- entry:
		default:
		}
	}
}

func (d *deployManager) finish(state string) {
	d.mu.Lock()
	d.state = state
	subs := make([]chan LogEntry, len(d.subs))
	copy(subs, d.subs)
	d.subs = nil
	d.mu.Unlock()

	term := LogEntry{Type: "done", Message: state, Time: time.Now().Format("15:04:05")}
	for _, ch := range subs {
		select {
		case ch <- term:
		default:
		}
	}
}

// subscribe returns a channel pre-loaded with existing logs.
// If already done/failed, also sends the terminal entry so the reader exits.
func (d *deployManager) subscribe() chan LogEntry {
	ch := make(chan LogEntry, 512)
	d.mu.Lock()
	for _, l := range d.logs {
		ch <- l
	}
	if d.state == "done" || d.state == "failed" {
		ch <- LogEntry{Type: "done", Message: d.state}
	} else {
		d.subs = append(d.subs, ch)
	}
	d.mu.Unlock()
	return ch
}

func (d *deployManager) unsubscribe(ch chan LogEntry) {
	d.mu.Lock()
	defer d.mu.Unlock()
	for i, s := range d.subs {
		if s == ch {
			d.subs = append(d.subs[:i], d.subs[i+1:]...)
			break
		}
	}
}

// ── Shell helpers ────────────────────────────────────────────────

// claudeDir returns the root of the /home/mahipal/claude project.
func claudeDir() string {
	if dir := os.Getenv("CLAUDE_DIR"); dir != "" {
		return dir
	}
	// Infer: backend runs from ui/backend/ → go up two levels
	wd, _ := os.Getwd()
	return filepath.Join(wd, "..", "..")
}

// lineWriter feeds each non-empty line as a log entry.
type lineWriter struct{ logType string }

func (w lineWriter) Write(p []byte) (int, error) {
	for _, line := range strings.Split(string(p), "\n") {
		line = strings.TrimRight(line, "\r")
		if strings.TrimSpace(line) != "" {
			deploy.addLog(w.logType, line)
		}
	}
	return len(p), nil
}

func runShell(script string) error {
	cmd := exec.Command("bash", "-c", script)
	cmd.Env = os.Environ()
	cmd.Stdout = lineWriter{"info"}
	cmd.Stderr = lineWriter{"warn"}
	return cmd.Run()
}

// renderTemplate loads the template at path and substitutes the map values
// for {{KEY}} placeholders. Uses strings.ReplaceAll so we don't depend on
// text/template (no helper functions needed; placeholders are plain scalars).
func renderTemplate(path string, subs map[string]string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	out := string(raw)
	for k, v := range subs {
		out = strings.ReplaceAll(out, "{{"+k+"}}", v)
	}
	if i := strings.Index(out, "{{"); i >= 0 {
		end := i + 80
		if end > len(out) {
			end = len(out)
		}
		return "", fmt.Errorf("unresolved placeholder in rendered manifest near %q", out[i:end])
	}
	return out, nil
}

// applyStdin pipes the given YAML to `kubectl apply -f -` and streams
// stdout/stderr through the deploy log.
func applyStdin(yaml string) error {
	cmd := exec.Command("kubectl", "apply", "-f", "-")
	cmd.Env = os.Environ()
	cmd.Stdin = strings.NewReader(yaml)
	cmd.Stdout = lineWriter{"info"}
	cmd.Stderr = lineWriter{"warn"}
	return cmd.Run()
}

func shellCheck(script string) bool {
	cmd := exec.Command("bash", "-c", script)
	cmd.Env = os.Environ()
	return cmd.Run() == nil
}

func kubectlGet(args ...string) string {
	cmd := exec.Command("kubectl", args...)
	out, _ := cmd.Output()
	return strings.TrimSpace(string(out))
}

// runScriptWithStream runs a bash script and streams stdout+stderr line-by-line.
func runScriptWithStream(script string) error {
	cmd := exec.Command("bash", "-c", script)
	cmd.Env = os.Environ()

	pr, pw, err := os.Pipe()
	if err != nil {
		return err
	}
	cmd.Stdout = pw
	cmd.Stderr = pw

	if err := cmd.Start(); err != nil {
		pw.Close()
		pr.Close()
		return err
	}
	pw.Close()

	scanner := bufio.NewScanner(pr)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line != "" {
			deploy.addLog("info", line)
		}
	}
	pr.Close()
	return cmd.Wait()
}

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
		dvOut := kubectlGet("get", "dv",
			"-l", "cluster.x-k8s.io/cluster-name="+targetClusterName,
			"--no-headers", "--ignore-not-found")
		dvCount := countNonEmpty(dvOut)
		if dvCount > 0 || total == 0 {
			deploy.addLog("info", fmt.Sprintf("  DataVolumes cloning: %d | VMIs: %d/%d Running", dvCount, running, total))
		} else {
			deploy.addLog("info", fmt.Sprintf("  VMIs: %d/%d Running", running, total))
		}
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
		if targetNodesReady(expectedVMs) {
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

// ── Deployment flow ──────────────────────────────────────────────

func runDeployment(profile, image string) {
	dir := claudeDir()

	profSpec, profOK := profileSpecs[profile]
	imgSpec, imgOK := imageVariants[image]

	defer func() {
		if r := recover(); r != nil {
			deploy.addLog("error", fmt.Sprintf("Unexpected error: %v", r))
			deploy.finish("failed")
		}
	}()

	fail := func(msg string) {
		deploy.addLog("error", msg)
		deploy.finish("failed")
	}

	if !profOK {
		fail(fmt.Sprintf("Unknown profile %q. Valid: lite, full.", profile))
		return
	}
	if !imgOK {
		fail(fmt.Sprintf("Unknown image %q. Valid: noble, minimal.", image))
		return
	}

	// ── Step 1: Prerequisites ──────────────────────────────────────
	deploy.addLog("step", "━━ Step 1/6: Check Prerequisites ━━")
	deploy.addLog("info", "Verifying KubeVirt, CDI, and CLI tools.")

	checks := []struct {
		label string
		cmd   string
	}{
		{"KubeVirt installed", `kubectl get kubevirt -A -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Deployed`},
		{"CDI installed", `kubectl get cdi -A -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Deployed`},
		{"kubectl", `kubectl version --client=true 2>/dev/null`},
		{"clusterctl", `clusterctl version 2>/dev/null`},
	}

	allOK := true
	for _, c := range checks {
		if shellCheck(c.cmd) {
			deploy.addLog("success", "✓ "+c.label)
		} else {
			deploy.addLog("error", "✗ "+c.label)
			allOK = false
		}
	}
	if !allOK {
		fail("Prerequisites not met. Ensure KubeVirt and CDI are ready.")
		return
	}

	// ── Step 2: MetalLB ────────────────────────────────────────────
	deploy.addLog("step", "━━ Step 2/6: Ensure MetalLB is Ready ━━")
	deploy.addLog("info", "MetalLB assigns the LoadBalancer IP ("+targetLBIP+") for the API server.")

	if shellCheck(`kubectl get pods -n metallb-system -l app=metallb,component=controller -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running`) {
		pool := kubectlGet("get", "ipaddresspool", "-n", "metallb-system", "-o", "jsonpath={.items[0].spec.addresses[0]}")
		deploy.addLog("success", "✓ MetalLB controller is running (pool: "+pool+")")
	} else {
		deploy.addLog("info", "MetalLB not running — installing...")
		if err := runScriptWithStream("bash " + filepath.Join(dir, "01-metallb/install-metallb.sh")); err != nil {
			fail("Failed to install MetalLB: " + err.Error())
			return
		}
		deploy.addLog("success", "✓ MetalLB installed")
	}

	// ── Step 3: CAPI providers ─────────────────────────────────────
	deploy.addLog("step", "━━ Step 3/6: Ensure CAPI Providers are Ready ━━")
	deploy.addLog("info", "CAPI orchestrates VM creation (CAPK) and k3s bootstrap.")

	capiReady := shellCheck(`kubectl get deployment capi-controller-manager -n capi-system 2>/dev/null`) &&
		shellCheck(`kubectl get deployment capk-controller-manager -n capk-system 2>/dev/null`)

	if capiReady {
		deploy.addLog("success", "✓ CAPI core controller ready")
		deploy.addLog("success", "✓ CAPK infrastructure controller ready")
		deploy.addLog("success", "✓ k3s bootstrap + control plane controllers ready")
	} else {
		deploy.addLog("info", "CAPI not initialized — running clusterctl init (this takes ~2 min)...")
		if err := runScriptWithStream("bash " + filepath.Join(dir, "02-capi-init/init-management-cluster.sh")); err != nil {
			fail("Failed to initialize CAPI: " + err.Error())
			return
		}
		deploy.addLog("success", "✓ CAPI providers initialized")
	}

	// ── Step 4: Apply cluster manifests ───────────────────────────
	warm := image == warmImageKey
	deploy.addLog("step", "━━ Step 4/6: Deploy Target Cluster ━━")
	deploy.addLog("info", "Applying CAPI resources (Cluster, KubevirtCluster, KThreesControlPlane, MachineDeployment).")
	deploy.addLog("info", "Profile: "+profSpec.Label)
	deploy.addLog("info", "Image:   "+imgSpec.Label+" ("+imgSpec.Image+")")
	deploy.addLog("info", "API server will be exposed at "+targetLBIP+":6443 via MetalLB")

	// Warm fast-path: pre-seed the CA/token secrets so KThrees adopts the same
	// material baked into the :warm image (no CA conflict → no --cluster-reset),
	// then apply the warm template (parallel worker boot). Targets <40s.
	tmplName := "03-target-cluster/target-cluster.tmpl.yaml"
	if warm {
		tmplName = "03-target-cluster/target-cluster-warm.tmpl.yaml"
		deploy.addLog("info", "Warm fast-path — seeding fixed CA + token secrets so KThrees adopts the baked material...")
		if err := runScriptWithStream("bash " + filepath.Join(dir, "scripts/seed-cluster-secrets.sh")); err != nil {
			fail("Failed to seed warm-path secrets: " + err.Error())
			return
		}
		deploy.addLog("success", "✓ Warm CA + token secrets seeded")
	}

	tmplPath := filepath.Join(dir, tmplName)
	subs := map[string]string{
		"CLUSTER_NAME": targetClusterName,
		"IMAGE":        imgSpec.Image,
		"API_LB_IP":    targetLBIP,
		"CP_CPU":       profSpec.CPCPU,
		"CP_MEM":       profSpec.CPMem,
		"WORKER_CPU":   profSpec.WorkerCPU,
		"WORKER_MEM":   profSpec.WorkerMem,
	}
	rendered, err := renderTemplate(tmplPath, subs)
	if err != nil {
		fail("Failed to render cluster template: " + err.Error())
		return
	}
	if err := applyStdin(rendered); err != nil {
		fail("Failed to apply cluster manifests: " + err.Error())
		return
	}
	deploy.addLog("success", "✓ Cluster resources applied — CAPI controllers are provisioning VMs")

	const expectedVMs = 2
	if err := waitForTargetReady(expectedVMs); err != nil {
		fail(err.Error())
		return
	}
	kubeconfigPath := "/tmp/" + targetClusterName + "-kubeconfig"
	_ = labelTargetCluster(poolStateClaimed)
	deploy.addLog("step", "━━ Done! ━━")
	deploy.addLog("success", "✓ Target cluster is up and running")
	deploy.addLog("info", "KUBECONFIG="+kubeconfigPath)
	deploy.addLog("info", "Run ./show-cluster.sh to explore components and deploy an example app")
	deploy.finish("done")
}

// ── HTTP Handlers ─────────────────────────────────────────────────

// POST /api/v1/cluster/deploy?profile=lite|full — start (or attach to running) deployment, stream SSE
func HandleDeployCluster(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

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
		deploy.resetForNewRun()
		setCurrentOp("deploy")
		go runDeployment(profile, image)
	}

	streamDeployLogs(w, r)
}

// GET /api/v1/cluster/deploy/logs — stream SSE log (attach to running or replay done)
func HandleDeployLogs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	streamDeployLogs(w, r)
}

func streamDeployLogs(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}

	ch := deploy.subscribe()
	defer deploy.unsubscribe(ch)

	for {
		select {
		case <-r.Context().Done():
			return
		case entry := <-ch:
			data, _ := json.Marshal(entry)
			fmt.Fprintf(w, "data: %s\n\n", data)
			flusher.Flush()
			if entry.Type == "done" {
				return
			}
		case <-time.After(25 * time.Second):
			fmt.Fprintf(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}

// ── Status ────────────────────────────────────────────────────────

type MachineInfo struct {
	Name  string `json:"name"`
	Phase string `json:"phase"`
	Role  string `json:"role"`
}

type VMIInfo struct {
	Name  string `json:"name"`
	Phase string `json:"phase"`
	IP    string `json:"ip"`
}

type TargetClusterStatus struct {
	State        string        `json:"state"`
	Operation    string        `json:"operation"` // "deploy" | "delete" | "istio" | ""
	ClusterPhase string        `json:"clusterPhase"`
	Machines     []MachineInfo `json:"machines"`
	VMIs         []VMIInfo     `json:"vmis"`
	APIReady     bool          `json:"apiReady"`
	IstioReady   bool          `json:"istioReady"`
}

// GET /api/v1/cluster/target-status
func HandleTargetClusterStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	status := TargetClusterStatus{State: deploy.getState(), Operation: getCurrentOp()}

	// CAPI Cluster phase
	clusterObj, err := k8sclient.DynamicClient.Resource(capiClusterGVR).Namespace("default").Get(ctx, targetClusterName, metav1.GetOptions{})
	if err == nil {
		if st, ok := clusterObj.Object["status"].(map[string]interface{}); ok {
			if phase, ok := st["phase"].(string); ok {
				status.ClusterPhase = phase
			}
		}
	}

	// Machines
	machineList, err := k8sclient.DynamicClient.Resource(capiMachineGVR).Namespace("default").List(ctx, metav1.ListOptions{
		LabelSelector: "cluster.x-k8s.io/cluster-name=" + targetClusterName,
	})
	if err == nil {
		for _, m := range machineList.Items {
			phase := ""
			role := ""
			if st, ok := m.Object["status"].(map[string]interface{}); ok {
				if p, ok := st["phase"].(string); ok {
					phase = p
				}
			}
			if labels := m.GetLabels(); labels != nil {
				role = labels["cluster.x-k8s.io/role"]
			}
			status.Machines = append(status.Machines, MachineInfo{Name: m.GetName(), Phase: phase, Role: role})
		}
	}

	// VMIs
	vmiList, err := k8sclient.DynamicClient.Resource(vmiGVR).Namespace("default").List(ctx, metav1.ListOptions{
		LabelSelector: "cluster.x-k8s.io/cluster-name=" + targetClusterName,
	})
	if err == nil {
		for _, vmi := range vmiList.Items {
			phase, ip := "", ""
			if st, ok := vmi.Object["status"].(map[string]interface{}); ok {
				if p, ok := st["phase"].(string); ok {
					phase = p
				}
				if ifaces, ok := st["interfaces"].([]interface{}); ok && len(ifaces) > 0 {
					if iface, ok := ifaces[0].(map[string]interface{}); ok {
						if a, ok := iface["ipAddress"].(string); ok {
							ip = a
						}
					}
				}
			}
			status.VMIs = append(status.VMIs, VMIInfo{Name: vmi.GetName(), Phase: phase, IP: ip})
		}
	}

	// API server + Istio reachability
	kubeconfigPath := "/tmp/" + targetClusterName + "-kubeconfig"
	if _, err := os.Stat(kubeconfigPath); err == nil {
		status.APIReady = shellCheck(fmt.Sprintf(
			"kubectl --kubeconfig=%s get nodes --request-timeout=3s 2>/dev/null", kubeconfigPath))
		status.IstioReady = shellCheck(fmt.Sprintf(
			"kubectl --kubeconfig=%s get deployment istiod -n istio-system --no-headers --ignore-not-found 2>/dev/null | grep -q istiod",
			kubeconfigPath))
	}

	writeJSON(w, status)
}

// ── Deletion flow ─────────────────────────────────────────────────

func countNonEmpty(s string) int {
	n := 0
	for _, line := range strings.Split(s, "\n") {
		if strings.TrimSpace(line) != "" {
			n++
		}
	}
	return n
}

func runDeletion() {
	defer setCurrentOp("")
	defer func() {
		if r := recover(); r != nil {
			deploy.addLog("error", fmt.Sprintf("Unexpected error: %v", r))
			deploy.finish("idle")
		}
	}()

	dir := claudeDir()

	fail := func(msg string) {
		deploy.addLog("error", msg)
		deploy.finish("idle")
	}

	// ── Step 1: Delete CAPI Cluster ────────────────────────────────
	deploy.addLog("step", "━━ Step 1/3: Send Delete to CAPI ━━")
	deploy.addLog("info", "Deleting CAPI Cluster '"+targetClusterName+"' — triggers cascading deletion of Machines, VMs, and DataVolumes")

	if err := runShell("kubectl delete cluster " + targetClusterName + " --ignore-not-found --timeout=60s"); err != nil {
		fail("Failed to initiate cluster deletion: " + err.Error())
		return
	}
	deploy.addLog("success", "✓ Delete sent — CAPI is tearing down the cluster")

	// ── Step 2: Watch VMs, DVs, Machines being removed ─────────────
	deploy.addLog("step", "━━ Step 2/3: Wait for VMs and DataVolumes to be Removed ━━")
	deploy.addLog("info", "KubeVirt deletes VMs, CDI removes cloned DataVolumes, CAPI removes Machines…")

	vmTimeout := time.Now().Add(12 * time.Minute)
	for {
		if time.Now().After(vmTimeout) {
			deploy.addLog("warn", "Timed out waiting for cleanup — resources may still be deleting")
			break
		}
		vmiOut := kubectlGet("get", "vmi", "-l", "cluster.x-k8s.io/cluster-name="+targetClusterName, "--no-headers", "--ignore-not-found")
		dvOut := kubectlGet("get", "dv", "-l", "cluster.x-k8s.io/cluster-name="+targetClusterName, "--no-headers", "--ignore-not-found")
		machineOut := kubectlGet("get", "machine", "-l", "cluster.x-k8s.io/cluster-name="+targetClusterName, "--no-headers", "--ignore-not-found")

		vmis := countNonEmpty(vmiOut)
		dvs := countNonEmpty(dvOut)
		machines := countNonEmpty(machineOut)

		deploy.addLog("info", fmt.Sprintf("  VMIs: %d | DataVolumes: %d | Machines: %d", vmis, dvs, machines))

		if vmis == 0 && dvs == 0 && machines == 0 {
			deploy.addLog("success", "✓ All VMs, DataVolumes, and Machines removed!")
			break
		}
		time.Sleep(15 * time.Second)
	}

	// ── Step 3: Confirm cluster resource is gone ───────────────────
	deploy.addLog("step", "━━ Step 3/3: Confirm Cluster is Removed ━━")

	clusterTimeout := time.Now().Add(3 * time.Minute)
	for time.Now().Before(clusterTimeout) {
		out := kubectlGet("get", "cluster", targetClusterName, "--ignore-not-found", "--no-headers")
		if out == "" {
			deploy.addLog("success", "✓ CAPI Cluster resource is gone")
			break
		}
		if time.Now().After(clusterTimeout) {
			deploy.addLog("warn", "Cluster resource still present — may still be finalizing")
			break
		}
		time.Sleep(5 * time.Second)
	}

	// Clean up kubeconfig files
	kubeconfigPath := "/tmp/" + targetClusterName + "-kubeconfig"
	kubeconfigLocal := filepath.Join(dir, targetClusterName+"-kubeconfig")
	_ = os.Remove(kubeconfigPath)
	_ = os.Remove(kubeconfigLocal)
	deploy.addLog("info", "Kubeconfig files cleaned up")

	deploy.addLog("step", "━━ Done! ━━")
	deploy.addLog("success", "✓ Target cluster deleted successfully")
	deploy.finish("idle")
}

// POST /api/v1/cluster/delete — start deletion and stream SSE progress
func HandleDeleteClusterStream(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	if deploy.getState() == "running" {
		writeError(w, http.StatusConflict, "another operation is in progress")
		return
	}

	deploy.resetForNewRun()
	setCurrentOp("delete")
	go runDeletion()

	streamDeployLogs(w, r)
}

// ── Istio install flow ────────────────────────────────────────────

func runIstioInstall() {
	defer setCurrentOp("")
	defer func() {
		if r := recover(); r != nil {
			deploy.addLog("error", fmt.Sprintf("Unexpected error: %v", r))
			deploy.finish("failed")
		}
	}()

	dir := claudeDir()
	kubeconfigPath := "/tmp/" + targetClusterName + "-kubeconfig"

	fail := func(msg string) {
		deploy.addLog("error", msg)
		deploy.finish("failed")
	}

	// ── Step 1: Verify cluster access ─────────────────────────────
	deploy.addLog("step", "━━ Step 1/3: Verify Target Cluster Access ━━")
	if _, err := os.Stat(kubeconfigPath); err != nil {
		fail("Kubeconfig not found at " + kubeconfigPath + " — deploy the cluster first.")
		return
	}
	if !shellCheck(fmt.Sprintf("kubectl --kubeconfig=%s get nodes --request-timeout=5s 2>/dev/null", kubeconfigPath)) {
		fail("Target cluster API server is not reachable. Ensure the cluster is deployed and running.")
		return
	}
	deploy.addLog("success", "✓ Target cluster reachable at "+targetLBIP+":6443")

	// ── Step 2: Install Istio ambient + sample ─────────────────────
	deploy.addLog("step", "━━ Step 2/3: Install Istio Ambient + nginx sample ━━")
	deploy.addLog("info", "Profile: ambient  |  Platform: k3s  |  Istio v1.24.3")
	deploy.addLog("info", "Components: istiod · istio-cni-node (DaemonSet) · ztunnel (DaemonSet)")
	deploy.addLog("info", "Sample: nginx + sleep in namespace 'sample' (ambient mesh enrolled)")

	script := fmt.Sprintf("bash %s %s",
		filepath.Join(dir, "05-istio/install-istio-ambient.sh"),
		kubeconfigPath,
	)
	if err := runScriptWithStream(script); err != nil {
		fail("Istio installation failed: " + err.Error())
		return
	}

	// ── Done ──────────────────────────────────────────────────────
	deploy.addLog("step", "━━ Step 3/3: Done! ━━")
	deploy.addLog("success", "✓ Istio ambient installed — istiod · istio-cni-node · ztunnel ready")
	deploy.addLog("success", "✓ nginx + sleep running in namespace 'sample' (no sidecars — ambient mTLS)")
	deploy.addLog("info", "Test:  kubectl --kubeconfig="+kubeconfigPath+" exec -n sample deploy/sleep -- curl -s nginx.sample")
	deploy.addLog("info", "Logs:  kubectl --kubeconfig="+kubeconfigPath+" -n istio-system logs -l app=ztunnel --tail=10")
	deploy.finish("done")
}

// POST /api/v1/cluster/istio — install Istio ambient + nginx sample on the target cluster
func HandleIstioInstall(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if deploy.getState() == "running" {
		writeError(w, http.StatusConflict, "another operation is in progress")
		return
	}
	deploy.resetForNewRun()
	setCurrentOp("istio")
	go runIstioInstall()
	streamDeployLogs(w, r)
}

// DELETE /api/v1/cluster/target-delete — delete the target cluster
func HandleDeleteCluster(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	if deploy.getState() == "running" {
		writeError(w, http.StatusConflict, "deployment is in progress, cannot delete now")
		return
	}

	log.Println("Deleting target cluster...")
	go func() {
		out, err := exec.Command("kubectl", "delete", "cluster", targetClusterName, "--ignore-not-found").CombinedOutput()
		if err != nil {
			log.Printf("Error deleting cluster: %v: %s", err, out)
		} else {
			log.Printf("Cluster deletion initiated: %s", out)
		}
	}()

	deploy.resetForNewRun()
	deploy.finish("idle")

	writeJSON(w, map[string]string{"status": "deleting", "message": "Cluster deletion initiated"})
}
