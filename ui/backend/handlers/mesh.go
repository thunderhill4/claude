package handlers

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"time"

	k8sclient "kubeui/backend/k8s"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
)

// MeshNode / MeshEdge mirror the frontend TopoNode/TopoEdge shape, minus the
// x/y coordinates — layout is now computed client-side by the force simulation.
type MeshNode struct {
	ID      string            `json:"id"`
	Label   string            `json:"label"`
	Type    string            `json:"type"` // cluster|gateway|service|workload|proxy|vm
	Status  string            `json:"status"`
	Cluster string            `json:"cluster,omitempty"`
	Meta    map[string]string `json:"meta,omitempty"`
}

type MeshEdge struct {
	From     string `json:"from"`
	To       string `json:"to"`
	Label    string `json:"label"`
	Protocol string `json:"protocol"`
	Dashed   bool   `json:"dashed,omitempty"`
}

// MeshGraph is the response. Source reports how live the data is:
//
//	live     — every overlay source answered
//	mixed    — some sources live, some fell back to the static skeleton
//	fallback — nothing live could be reached
type MeshGraph struct {
	Nodes  []MeshNode `json:"nodes"`
	Edges  []MeshEdge `json:"edges"`
	Source string     `json:"source"`
}

// GET /api/v1/mesh/topology
//
// Strategy: start from a static skeleton (so cluster1 — which the backend has
// no kubeconfig for — and the overall shape are always present), then overlay
// live state where the backend's clients can reach it: real KubeVirt VM
// status/IP on cluster2, cluster2 reachability, and the target k3s cluster via
// its kubeconfig. Any failing source simply leaves the skeleton value in place;
// the handler never 500s and never renders blank.
func HandleMeshTopology(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()

	graph := staticMesh()
	live, fellBack := 0, 0

	// Overlay 1: cluster2 reachability + real node names.
	if nodeList, err := k8sclient.Clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{}); err == nil {
		names := make([]string, 0, len(nodeList.Items))
		for _, n := range nodeList.Items {
			names = append(names, n.Name)
		}
		setNodeStatus(graph, "cluster2", "healthy")
		setNodeMeta(graph, "cluster2", "kindNodes", fmt.Sprintf("%d", len(names)))
		if len(names) > 0 {
			setNodeMeta(graph, "cluster2", "nodes", joinTrunc(names, 3))
		}
		live++
	} else {
		log.Printf("mesh: cluster2 nodes unreachable: %v", err)
		setNodeStatus(graph, "cluster2", "degraded")
		fellBack++
	}

	// Overlay 2: real KubeVirt VM status/IP (target-cluster CP + worker).
	if vms := listVirtualMachines(ctx, ""); len(vms) > 0 {
		for _, vm := range vms {
			id := vmNodeID(vm.Name)
			if id == "" {
				continue
			}
			setNodeStatus(graph, id, vmStatusToHealth(vm.Status))
			setNodeMeta(graph, id, "phase", vm.Status)
			if vm.IPAddress != "" {
				setNodeMeta(graph, id, "ip", vm.IPAddress)
			}
			if vm.Node != "" {
				setNodeMeta(graph, id, "host", vm.Node)
			}
		}
		live++
	} else {
		log.Printf("mesh: no KubeVirt VMs visible; keeping skeleton VM status")
		fellBack++
	}

	// Overlay 3: the target k3s cluster, reached via its kubeconfig.
	if applyTargetOverlay(ctx, graph) {
		live++
	} else {
		// Target unreachable (stale/rotated CA, cluster down): degrade the
		// target-side nodes so the HUD honestly shows it can't be seen.
		for _, n := range graph.Nodes {
			if n.Cluster == "target-cluster" {
				setNodeStatus(graph, n.ID, "degraded")
			}
		}
		fellBack++
	}

	switch {
	case fellBack == 0:
		graph.Source = "live"
	case live == 0:
		graph.Source = "fallback"
	default:
		graph.Source = "mixed"
	}

	writeJSON(w, graph)
}

// applyTargetOverlay builds a clientset from the target-cluster kubeconfig and
// enriches the target-side nodes with real state. Returns true if the target
// cluster was reachable. See the CLAUDE.md pitfall: the target CA rotates on
// every redeploy, so a stale kubeconfig makes this fail — hence the bool.
func applyTargetOverlay(ctx context.Context, graph *MeshGraph) bool {
	cfg, err := clientcmd.BuildConfigFromFlags("", targetKubeconfigPath())
	if err != nil {
		log.Printf("mesh: target kubeconfig unusable: %v", err)
		return false
	}
	cfg.Timeout = 6 * time.Second
	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		log.Printf("mesh: target clientset: %v", err)
		return false
	}

	// A single list call doubles as the reachability probe.
	svcs, err := cs.CoreV1().Services("sample").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("mesh: target services unreachable: %v", err)
		return false
	}

	setNodeStatus(graph, "target", "healthy")
	for _, s := range svcs.Items {
		switch s.Name {
		case "nginx":
			setNodeStatus(graph, "tc-nginx", "healthy")
			if s.Spec.ClusterIP != "" {
				setNodeMeta(graph, "tc-nginx", "clusterIP", s.Spec.ClusterIP)
			}
		case "nginx-nodeport":
			setNodeStatus(graph, "tc-nginx-np", "healthy")
		}
	}

	// ztunnel pods (ambient data plane) — enrich per-node readiness if present.
	if pods, err := cs.CoreV1().Pods("istio-system").List(ctx, metav1.ListOptions{
		LabelSelector: "app=ztunnel",
	}); err == nil {
		ready := 0
		for _, p := range pods.Items {
			for _, cs := range p.Status.ContainerStatuses {
				if cs.Ready {
					ready++
					break
				}
			}
		}
		setNodeMeta(graph, "tc-ztunnel-cp", "ztunnelPods", fmt.Sprintf("%d/%d ready", ready, len(pods.Items)))
	}

	return true
}

// vmNodeID maps a real KubeVirt VM name to the skeleton node it enriches.
func vmNodeID(vmName string) string {
	switch vmName {
	case "target-cluster-cp":
		return "c2-vm-cp"
	case "target-cluster-worker":
		return "c2-vm-worker"
	}
	return ""
}

func vmStatusToHealth(status string) string {
	switch status {
	case "Running":
		return "healthy"
	case "Provisioning", "Starting", "Stopping":
		return "degraded"
	case "", "Stopped", "Failed":
		return "error"
	default:
		return "degraded"
	}
}

func joinTrunc(items []string, max int) string {
	if len(items) <= max {
		return joinComma(items)
	}
	return joinComma(items[:max]) + fmt.Sprintf(" +%d", len(items)-max)
}

func joinComma(items []string) string {
	out := ""
	for i, s := range items {
		if i > 0 {
			out += ", "
		}
		out += s
	}
	return out
}

// setNodeStatus / setNodeMeta mutate a node in-place by id (no-op if absent).
func setNodeStatus(graph *MeshGraph, id, status string) {
	for i := range graph.Nodes {
		if graph.Nodes[i].ID == id {
			graph.Nodes[i].Status = status
			return
		}
	}
}

func setNodeMeta(graph *MeshGraph, id, key, val string) {
	for i := range graph.Nodes {
		if graph.Nodes[i].ID == id {
			if graph.Nodes[i].Meta == nil {
				graph.Nodes[i].Meta = map[string]string{}
			}
			graph.Nodes[i].Meta[key] = val
			return
		}
	}
}

// staticMesh is the known cross-cluster topology (ported from the frontend's
// TopologyView consts, minus coordinates). It is the skeleton the live
// overlays enrich, and the guaranteed fallback when nothing is reachable.
func staticMesh() *MeshGraph {
	return &MeshGraph{
		Nodes: []MeshNode{
			// cluster1 (Kind) — no kubeconfig on the backend, always static.
			{ID: "cluster1", Label: "cluster1 (Kind)", Type: "cluster", Status: "healthy"},
			{ID: "c1-istiod", Label: "istiod", Type: "gateway", Status: "healthy", Cluster: "cluster1", Meta: map[string]string{"namespace": "istio-system"}},
			{ID: "c1-ztunnel", Label: "ztunnel", Type: "gateway", Status: "healthy", Cluster: "cluster1", Meta: map[string]string{"namespace": "istio-system"}},
			{ID: "c1-httpbin", Label: "httpbin", Type: "service", Status: "healthy", Cluster: "cluster1", Meta: map[string]string{"namespace": "mc-demo", "port": "8000", "ip": "10.96.161.47"}},
			{ID: "c1-httpbin-lb", Label: "httpbin-lb", Type: "service", Status: "healthy", Cluster: "cluster1", Meta: map[string]string{"namespace": "mc-demo", "type": "LoadBalancer", "ip": "172.18.255.200"}},
			{ID: "c1-sleep", Label: "sleep", Type: "workload", Status: "healthy", Cluster: "cluster1", Meta: map[string]string{"namespace": "mc-demo"}},
			{ID: "c1-httpbin-pod", Label: "httpbin-pod", Type: "workload", Status: "healthy", Cluster: "cluster1", Meta: map[string]string{"namespace": "mc-demo", "image": "kong/httpbin"}},
			{ID: "c1-se-nginx", Label: "SE: nginx.target-cluster.global", Type: "service", Status: "healthy", Cluster: "cluster1", Meta: map[string]string{"kind": "ServiceEntry", "resolution": "STATIC"}},

			// cluster2 (Management) — live overlay enriches this.
			{ID: "cluster2", Label: "cluster2 (Mgmt)", Type: "cluster", Status: "healthy"},
			{ID: "c2-proxy", Label: "target-cluster-nginx", Type: "proxy", Status: "healthy", Cluster: "cluster2", Meta: map[string]string{"type": "LoadBalancer", "ip": "172.18.255.216", "port": "8000→30080"}},
			{ID: "c2-vm-cp", Label: "virt-launcher (CP)", Type: "vm", Status: "healthy", Cluster: "cluster2", Meta: map[string]string{"vm": "target-cluster-cp"}},
			{ID: "c2-vm-worker", Label: "virt-launcher (Worker)", Type: "vm", Status: "degraded", Cluster: "cluster2", Meta: map[string]string{"vm": "target-cluster-worker"}},

			// target-cluster (k3s in VMs) — live overlay via kubeconfig.
			{ID: "target", Label: "target-cluster (k3s VM)", Type: "cluster", Status: "healthy"},
			{ID: "tc-istiod", Label: "istiod", Type: "gateway", Status: "healthy", Cluster: "target-cluster", Meta: map[string]string{"namespace": "istio-system"}},
			{ID: "tc-ztunnel-cp", Label: "ztunnel (CP)", Type: "gateway", Status: "healthy", Cluster: "target-cluster", Meta: map[string]string{"namespace": "istio-system", "node": "CP"}},
			{ID: "tc-ztunnel-wk", Label: "ztunnel (Worker)", Type: "gateway", Status: "error", Cluster: "target-cluster", Meta: map[string]string{"namespace": "istio-system", "node": "Worker", "note": "Not Ready"}},
			{ID: "tc-nginx", Label: "nginx", Type: "service", Status: "healthy", Cluster: "target-cluster", Meta: map[string]string{"namespace": "sample", "port": "80", "clusterIP": "10.43.185.78"}},
			{ID: "tc-nginx-np", Label: "nginx-nodeport", Type: "service", Status: "healthy", Cluster: "target-cluster", Meta: map[string]string{"namespace": "sample", "type": "NodePort", "nodePort": "30080"}},
			{ID: "tc-sleep", Label: "sleep", Type: "workload", Status: "healthy", Cluster: "target-cluster", Meta: map[string]string{"namespace": "sample"}},
			{ID: "tc-nginx-pod", Label: "nginx-pod", Type: "workload", Status: "healthy", Cluster: "target-cluster", Meta: map[string]string{"namespace": "sample", "image": "nginx"}},
			{ID: "tc-se-httpbin", Label: "SE: httpbin.cluster1.global", Type: "service", Status: "healthy", Cluster: "target-cluster", Meta: map[string]string{"kind": "ServiceEntry", "resolution": "STATIC"}},
		},
		Edges: []MeshEdge{
			{From: "c1-sleep", To: "c1-httpbin", Label: "local", Protocol: "HTTP"},
			{From: "c1-httpbin", To: "c1-httpbin-pod", Label: "", Protocol: "HTTP"},
			{From: "c1-httpbin", To: "c1-httpbin-lb", Label: "LB expose", Protocol: "HTTP"},
			{From: "c1-ztunnel", To: "c1-httpbin", Label: "L4", Protocol: "mTLS", Dashed: true},

			{From: "c1-sleep", To: "c1-se-nginx", Label: "cross-cluster", Protocol: "HTTP"},
			{From: "c1-se-nginx", To: "c2-proxy", Label: "172.18.255.216:8000", Protocol: "HTTP", Dashed: true},
			{From: "c2-proxy", To: "c2-vm-cp", Label: ":30080", Protocol: "TCP"},
			{From: "c2-vm-cp", To: "tc-nginx-np", Label: "NodePort", Protocol: "TCP"},
			{From: "tc-nginx-np", To: "tc-nginx", Label: "", Protocol: "HTTP"},
			{From: "tc-nginx", To: "tc-nginx-pod", Label: "", Protocol: "HTTP"},

			{From: "tc-sleep", To: "tc-se-httpbin", Label: "cross-cluster", Protocol: "HTTP"},
			{From: "tc-se-httpbin", To: "c1-httpbin-lb", Label: "172.18.255.200:8000", Protocol: "HTTP", Dashed: true},

			{From: "tc-sleep", To: "tc-nginx", Label: "local", Protocol: "HTTP"},
			{From: "tc-ztunnel-cp", To: "tc-nginx", Label: "L4", Protocol: "mTLS", Dashed: true},

			{From: "c2-vm-cp", To: "target", Label: "hosts", Protocol: "KubeVirt", Dashed: true},
			{From: "c2-vm-worker", To: "target", Label: "hosts", Protocol: "KubeVirt", Dashed: true},
		},
	}
}
