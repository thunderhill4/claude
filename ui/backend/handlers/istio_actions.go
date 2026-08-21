package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os/exec"
	"strings"
	"time"

	k8sclient "kubeui/backend/k8s"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
)

// Action endpoints for the Istio demo. Every one of these MUTATES or drives a
// live cluster, so they follow three rules:
//
//  1. No caller-supplied name reaches a namespace, deployment, host, or command
//     line. Targets come from the constants/allowlist in istio.go.
//  2. Anything that changes cluster state restores it on EVERY exit path,
//     including client disconnect.
//  3. Numeric inputs are clamped.

// ── POST /api/v1/istio/probe ────────────────────────────────────────────────

type probeRequest struct {
	Count    int  `json:"count"`
	Internal bool `json:"internal"` // send x-demo-user: internal
}

type probeEvent struct {
	Type    string `json:"type"` // step|result|summary|error|done
	Seq     int    `json:"seq,omitempty"`
	Version string `json:"version,omitempty"`
	Code    int    `json:"code,omitempty"`
	V1      int    `json:"v1,omitempty"`
	V2      int    `json:"v2,omitempty"`
	Message string `json:"message,omitempty"`
}

// HandleIstioProbe drives Act 1's canary: N requests through the edge Gateway,
// streamed one event per response so the UI can chart the split as it fills in
// rather than after the fact.
func HandleIstioProbe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var req probeRequest
	_ = json.NewDecoder(r.Body).Decode(&req)
	if req.Count <= 0 {
		req.Count = 100
	}
	if req.Count > 200 {
		req.Count = 200 // hard cap: this hits a real gateway
	}

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	send := func(e probeEvent) {
		b, _ := json.Marshal(e)
		fmt.Fprintf(w, "data: %s\n\n", b)
		flusher.Flush()
	}

	hdr := ""
	if req.Internal {
		hdr = "internal"
	}
	send(probeEvent{Type: "step", Message: fmt.Sprintf(
		"Sending %d requests to https://%s via %s", req.Count, demoHost, edgeGatewayIP)})

	v1, v2 := 0, 0
	for i := 1; i <= req.Count; i++ {
		select {
		case <-r.Context().Done():
			return
		default:
		}
		version, code := probeOnce(r.Context(), hdr)
		switch version {
		case "v1":
			v1++
		case "v2":
			v2++
		}
		send(probeEvent{Type: "result", Seq: i, Version: version, Code: code, V1: v1, V2: v2})
	}

	send(probeEvent{Type: "summary", V1: v1, V2: v2, Message: fmt.Sprintf(
		"v1=%d v2=%d (%d%% to v2)", v1, v2, pct(v2, v1+v2))})
	fmt.Fprint(w, "data: [DONE]\n\n")
	flusher.Flush()
}

func pct(n, total int) int {
	if total == 0 {
		return 0
	}
	return n * 100 / total
}

// probeOnce issues one request through the edge gateway and reports which
// backend answered. curl is used rather than net/http because the demo's cert
// is signed by a local CA and resolved via --resolve; replicating that in Go
// would mean shipping the CA into the process for no benefit.
func probeOnce(ctx context.Context, internalHeader string) (string, int) {
	// Body already goes to stdout; -w appends the status code after it. An
	// explicit `-o /dev/stdout` on top of that is redundant and interleaves
	// badly when stdout is a pipe rather than a terminal.
	args := []string{
		"-s", "-w", "\n%{http_code}",
		"--max-time", "10",
		"--resolve", demoHost + ":443:" + edgeGatewayIP,
		"-k", // chain validated separately in the overview; this probe tests routing
	}
	if internalHeader != "" {
		args = append(args, "-H", "x-demo-user: "+internalHeader)
	}
	args = append(args, "https://"+demoHost+"/")

	out, err := exec.CommandContext(ctx, "curl", args...).CombinedOutput() //nolint:gosec // fixed args, no caller input
	if err != nil {
		log.Printf("istio probe: curl failed: %v (out=%.120q)", err, string(out))
		return "", 0
	}
	body := string(out)
	code := 0
	if i := strings.LastIndex(body, "\n"); i >= 0 {
		fmt.Sscanf(strings.TrimSpace(body[i+1:]), "%d", &code)
		body = body[:i]
	}
	switch {
	case strings.Contains(body, "echo-v2"):
		return "v2", code
	case strings.Contains(body, "echo-v1"):
		return "v1", code
	}
	return "", code
}

// ── POST /api/v1/istio/identity-probe ───────────────────────────────────────

type IdentityProbeResult struct {
	Identity string `json:"identity"`
	Path     string `json:"path"`
	Code     int    `json:"code"`
	Allowed  bool   `json:"allowed"`
}

type IdentityProbeResponse struct {
	Results []IdentityProbeResult `json:"results"`
	XFCC    string                `json:"xfcc,omitempty"`
	Source  string                `json:"source"`
	Notes   []string              `json:"notes,omitempty"`
}

// HandleIstioIdentityProbe drives Act 2: the same request from two SPIFFE
// identities, showing the waypoint allow one and deny the other, plus the XFCC
// header carrying the caller's real identity.
func HandleIstioIdentityProbe(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()

	st := &sourceTracker{}
	out := IdentityProbeResponse{Results: []IdentityProbeResult{}}

	probes := []struct {
		deploy, identity, path string
	}{
		{clientTrusted, "sa/trusted", "/secure"},
		{clientUntruste, "sa/untrusted", "/secure"},
		{clientUntruste, "sa/untrusted", "/public"},
	}
	for _, p := range probes {
		code, err := execCurlCode(ctx, p.deploy, "http://"+demoService+p.path)
		if err != nil {
			st.fail(p.deploy+p.path, err)
			continue
		}
		st.ok()
		out.Results = append(out.Results, IdentityProbeResult{
			Identity: p.identity, Path: p.path, Code: code, Allowed: code == 200,
		})
	}

	if body, err := execCurlBody(ctx, clientTrusted, "http://"+demoService+"/public"); err == nil {
		for _, line := range strings.Split(body, "\n") {
			if strings.Contains(strings.ToLower(line), "x-forwarded-client-cert") {
				out.XFCC = strings.TrimSpace(line)
				break
			}
		}
	}

	out.Source = st.String()
	out.Notes = st.notes
	writeJSON(w, out)
}

func execCurlCode(ctx context.Context, deploy, url string) (int, error) {
	out, err := exec.CommandContext(ctx, "kubectl", //nolint:gosec // fixed args
		"--context="+ctxCluster1, "exec", "-n", nsDemoApps, "deploy/"+deploy, "-c", "curl", "--",
		"curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "10", url,
	).Output()
	if err != nil {
		return 0, err
	}
	code := 0
	fmt.Sscanf(strings.TrimSpace(string(out)), "%d", &code)
	return code, nil
}

func execCurlBody(ctx context.Context, deploy, url string) (string, error) {
	out, err := exec.CommandContext(ctx, "kubectl", //nolint:gosec // fixed args
		"--context="+ctxCluster1, "exec", "-n", nsDemoApps, "deploy/"+deploy, "-c", "curl", "--",
		"curl", "-s", "--max-time", "10", url,
	).Output()
	return string(out), err
}

// ── POST /api/v1/istio/failover ─────────────────────────────────────────────

// HandleIstioFailover drives Act 3: scale cluster1's local backends to zero and
// show traffic continue to be served from cluster2, with no config change.
//
// ACT 2 BREAKS ACT 3, and it does so silently. Measured on this cluster:
//
//	istioctl proxy-config endpoints deploy/waypoint.demo-apps
//	  -> only LOCAL pod IPs (10.244.0.42/.43/.44) for echo.demo-apps
//	istioctl ztunnel-config workload
//	  -> network2/SplitHorizonWorkload/.../172.18.255.221/... IS present
//
// Cross-cluster endpoints are programmed into ztunnel (L4). A waypoint resolves
// only local endpoints for the services it fronts, so once Act 2 enrolls the
// namespace, scaling the local backends to zero yields 503 on every request
// instead of failing over — the mesh is behaving correctly, the traffic simply
// never reaches ztunnel's remote endpoint.
//
// Fix: opt the global Service out of the waypoint for the duration with
// `istio.io/use-waypoint: none`. Verified: 503 on every request with the
// waypoint in path; 200 within 6s of the opt-out.
//
// SAFETY: this leaves the cluster broken if the restore is skipped. Restore runs
// from a defer with its OWN background context, so it still executes when the
// client disconnects mid-stream or the request context is cancelled — the
// failure mode that would otherwise leave demo-apps with zero endpoints and make
// every later act look broken for non-obvious reasons. It restores BOTH the
// replica counts and the waypoint label.
func HandleIstioFailover(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming unsupported")
		return
	}
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")

	send := func(e probeEvent) {
		b, _ := json.Marshal(e)
		fmt.Fprintf(w, "data: %s\n\n", b)
		flusher.Flush()
	}

	cc, err := k8sclient.ForContext(ctxCluster1)
	if err != nil {
		send(probeEvent{Type: "error", Message: "cluster1 unreachable: " + err.Error()})
		fmt.Fprint(w, "data: [DONE]\n\n")
		flusher.Flush()
		return
	}

	// Restore unconditionally, on a context that survives client disconnect.
	defer func() {
		rctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
		defer cancel()
		for name, replicas := range scalableDeployments {
			if err := scaleDeployment(rctx, cc, name, replicas); err != nil {
				log.Printf("istio failover: RESTORE FAILED for %s: %v", name, err)
			}
		}
		if err := setWaypointOptOut(rctx, cc, false); err != nil {
			log.Printf("istio failover: RESTORE FAILED for waypoint label: %v", err)
		}
		log.Printf("istio failover: replicas + waypoint label restored")
	}()

	send(probeEvent{Type: "step", Message: "Opting the global Service out of the waypoint (see handler docs: a waypoint resolves only local endpoints)"})
	if err := setWaypointOptOut(r.Context(), cc, true); err != nil {
		send(probeEvent{Type: "error", Message: "waypoint opt-out failed: " + err.Error()})
		fmt.Fprint(w, "data: [DONE]\n\n")
		flusher.Flush()
		return
	}

	send(probeEvent{Type: "step", Message: "Baseline: sending traffic with cluster1 endpoints healthy"})
	okc, failc := runFailoverProbe(r.Context(), 5)
	send(probeEvent{Type: "result", Message: fmt.Sprintf("baseline success=%d failed=%d", okc, failc)})

	send(probeEvent{Type: "step", Message: "Scaling cluster1 echo-v1 + echo-v2 to 0 (no config change)"})
	for name := range scalableDeployments {
		if err := scaleDeployment(r.Context(), cc, name, 0); err != nil {
			send(probeEvent{Type: "error", Message: fmt.Sprintf("scale %s: %v", name, err)})
			fmt.Fprint(w, "data: [DONE]\n\n")
			flusher.Flush()
			return
		}
	}

	// Wait for local endpoints to actually drain out of ztunnel.
	for i := 0; i < 15; i++ {
		select {
		case <-r.Context().Done():
			return
		case <-time.After(2 * time.Second):
		}
		if n := runningEchoPods(r.Context(), cc); n == 0 {
			break
		}
	}

	// Convergence is measured, not assumed. Counting the 20-request sample from
	// the instant of scale-down conflates "failover does not work" with "failover
	// has not converged yet" — the first reads as a broken mesh, the second is
	// normal and worth showing as a number.
	send(probeEvent{Type: "step", Message: "cluster1 has 0 local endpoints — waiting for cross-cluster routing to converge"})
	converged := false
	start := time.Now()
	for i := 0; i < 30; i++ {
		select {
		case <-r.Context().Done():
			return
		default:
		}
		if code, err := execCurlCode(r.Context(), clientTrusted, "http://"+demoService+"/"); err == nil && code == 200 {
			converged = true
			break
		}
		time.Sleep(2 * time.Second)
	}
	if converged {
		send(probeEvent{Type: "result", Message: fmt.Sprintf(
			"converged in %.0fs — now serving from cluster2", time.Since(start).Seconds())})
	} else {
		send(probeEvent{Type: "error", Message: "no successful response within 60s of scale-down"})
	}

	send(probeEvent{Type: "step", Message: "Measuring steady state: 20 requests to the same Service name"})
	okc, failc = runFailoverProbe(r.Context(), 20)
	send(probeEvent{Type: "summary", V1: okc, V2: failc, Message: fmt.Sprintf(
		"success=%d failed=%d", okc, failc)})
	if okc >= 18 {
		send(probeEvent{Type: "result", Message: "Traffic failed over to cluster2 — no config change, no app restart"})
	} else {
		send(probeEvent{Type: "error", Message: fmt.Sprintf("failover incomplete: %d/20 failed", failc)})
	}

	send(probeEvent{Type: "step", Message: "Restoring cluster1 replicas…"})
	fmt.Fprint(w, "data: [DONE]\n\n")
	flusher.Flush()
}

// setWaypointOptOut adds or removes `istio.io/use-waypoint: none` on the global
// Service, taking it out of / putting it back into the waypoint's path.
// Scoped to the one Service named in the constants — nothing else is reachable.
func setWaypointOptOut(ctx context.Context, cc *k8sclient.ClusterClients, optOut bool) error {
	var patch string
	if optOut {
		patch = `{"metadata":{"labels":{"istio.io/use-waypoint":"none"}}}`
	} else {
		// A null value removes the label under a strategic-merge patch.
		patch = `{"metadata":{"labels":{"istio.io/use-waypoint":null}}}`
	}
	_, err := cc.Clientset.CoreV1().Services(nsDemoApps).Patch(
		ctx, demoService, types.StrategicMergePatchType, []byte(patch), metav1.PatchOptions{},
	)
	return err
}

func scaleDeployment(ctx context.Context, cc *k8sclient.ClusterClients, name string, replicas int32) error {
	if _, allowed := scalableDeployments[name]; !allowed {
		return fmt.Errorf("deployment %q is not scalable through this API", name)
	}
	s, err := cc.Clientset.AppsV1().Deployments(nsDemoApps).GetScale(ctx, name, metav1.GetOptions{})
	if err != nil {
		return err
	}
	s.Spec.Replicas = replicas
	_, err = cc.Clientset.AppsV1().Deployments(nsDemoApps).UpdateScale(ctx, name, s, metav1.UpdateOptions{})
	return err
}

func runningEchoPods(ctx context.Context, cc *k8sclient.ClusterClients) int {
	pods, err := cc.Clientset.CoreV1().Pods(nsDemoApps).List(ctx, metav1.ListOptions{
		LabelSelector: "app=" + demoService,
	})
	if err != nil {
		return -1
	}
	n := 0
	for _, p := range pods.Items {
		if p.DeletionTimestamp == nil && p.Status.Phase == "Running" {
			n++
		}
	}
	return n
}

// runFailoverProbe calls the global Service from inside the mesh, which is the
// only vantage point where cross-cluster routing applies.
func runFailoverProbe(ctx context.Context, n int) (int, int) {
	okc, failc := 0, 0
	for i := 0; i < n; i++ {
		select {
		case <-ctx.Done():
			return okc, failc
		default:
		}
		code, err := execCurlCode(ctx, clientTrusted, "http://"+demoService+"/")
		if err == nil && code == 200 {
			okc++
		} else {
			failc++
		}
	}
	return okc, failc
}

// prometheusSeriesCount runs an instant query against the in-cluster Prometheus.
//
// NOTE the container name: `prometheus-server`, NOT `prometheus`. The istio
// addon pod runs prometheus-server plus prometheus-server-configmap-reload, and
// `-c prometheus` fails with "container prometheus is not valid for pod".
func prometheusSeriesCount(ctx context.Context, query string) (int, error) {
	out, err := exec.CommandContext(ctx, "kubectl", //nolint:gosec // fixed args
		"--context="+ctxCluster1, "exec", "-n", "istio-system",
		"deploy/prometheus", "-c", "prometheus-server", "--",
		"wget", "-qO-", "http://localhost:9090/api/v1/query?query="+query,
	).Output()
	if err != nil {
		return 0, err
	}
	var payload struct {
		Data struct {
			Result []struct {
				Value []interface{} `json:"value"`
			} `json:"result"`
		} `json:"data"`
	}
	if err := json.Unmarshal(out, &payload); err != nil {
		return 0, err
	}
	if len(payload.Data.Result) == 0 || len(payload.Data.Result[0].Value) < 2 {
		return 0, nil
	}
	s, _ := payload.Data.Result[0].Value[1].(string)
	n := 0
	fmt.Sscanf(s, "%d", &n)
	return n, nil
}
