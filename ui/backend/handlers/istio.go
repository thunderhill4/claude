package handlers

import (
	"context"
	"fmt"
	"net/http"
	"sort"
	"strings"
	"time"

	k8sclient "kubeui/backend/k8s"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/apis/meta/v1/unstructured"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/dynamic"
)

// Contexts for the two mesh members. cluster2 is also reachable through the
// package-level client, but going through ForContext for both keeps the code
// symmetric and makes the cluster1/cluster2 pairing explicit.
const (
	ctxCluster1 = "kind-cluster1"
	ctxCluster2 = "kind-cluster2"
)

// Fixed coordinates of the 07-istio-advanced demo.
//
// These are constants on purpose. The action endpoints below MUTATE a live
// cluster (scaling deployments, running probes), so no caller-supplied name is
// ever allowed to reach a namespace, deployment, or host. Anything the demo can
// touch is enumerated here; anything else is simply not reachable through the
// API. See also the safeName guard in cross_cluster.go.
const (
	nsDemoApps     = "demo-apps"
	nsGatewayInfra = "gateway-infra"
	nsAIGateway    = "ai-gateway"

	demoHost    = "echo.demo.istio.local"
	demoService = "echo"

	edgeGatewayIP  = "172.18.255.201"
	aiGatewayIP    = "172.18.255.203"
	kialiURL       = "http://172.18.255.204:20001"
	clientTrusted  = "client-trusted"
	clientUntruste = "client-untrusted"
)

// scalableDeployments is the closed set the failover action may scale, with the
// replica count it must be restored to. A deployment not listed here cannot be
// touched through the API at all.
var scalableDeployments = map[string]int32{
	"echo-v1": 2,
	"echo-v2": 1,
}

// Gateway API and Istio resources, all read through the dynamic client since
// the backend does not vendor their typed clients.
var (
	gvrGateway = schema.GroupVersionResource{
		Group: "gateway.networking.k8s.io", Version: "v1", Resource: "gateways",
	}
	gvrHTTPRoute = schema.GroupVersionResource{
		Group: "gateway.networking.k8s.io", Version: "v1", Resource: "httproutes",
	}
	// ListenerSet graduated from XListenerSet (gateway.networking.x-k8s.io) to
	// this group/version in Gateway API v1.5. Most write-ups still say the old
	// name; querying that returns nothing.
	gvrListenerSet = schema.GroupVersionResource{
		Group: "gateway.networking.k8s.io", Version: "v1", Resource: "listenersets",
	}
	gvrAuthorizationPolicy = schema.GroupVersionResource{
		Group: "security.istio.io", Version: "v1", Resource: "authorizationpolicies",
	}
)

// ── source tracking ─────────────────────────────────────────────────────────
//
// Mirrors handlers/mesh.go: a partially-reachable environment must render
// partial truth rather than 500 or a blank page. In-cluster there is no
// cluster1 context at all, which is expected, not an error.

type sourceTracker struct {
	live     int
	fellBack int
	notes    []string
}

func (s *sourceTracker) ok() { s.live++ }
func (s *sourceTracker) fail(what string, err error) {
	s.fellBack++
	s.notes = append(s.notes, fmt.Sprintf("%s: %v", what, err))
}
func (s *sourceTracker) String() string {
	switch {
	case s.fellBack == 0 && s.live > 0:
		return "live"
	case s.live == 0:
		return "fallback"
	default:
		return "mixed"
	}
}

// condition reads status.conditions[type=<want>] from an unstructured object,
// returning (status, reason). Used for Gateway "Programmed".
func condition(obj *unstructured.Unstructured, want string) (string, string) {
	conds, found, err := unstructured.NestedSlice(obj.Object, "status", "conditions")
	if err != nil || !found {
		return "", ""
	}
	for _, c := range conds {
		m, ok := c.(map[string]interface{})
		if !ok {
			continue
		}
		if m["type"] == want {
			st, _ := m["status"].(string)
			reason, _ := m["reason"].(string)
			return st, reason
		}
	}
	return "", ""
}

// routeCondition reads an HTTPRoute's per-parent condition.
//
// CRITICAL: a route's conditions live under status.parents[*].conditions, NOT
// status.conditions. Reading the wrong path yields "" which renders as accepted
// — exactly backwards for the rogue-hijack route, whose whole purpose is to be
// visibly REJECTED with NotAllowedByListeners. Same trap that makes
// `kubectl wait --for=condition=Accepted httproute/x` silently time out.
func routeCondition(obj *unstructured.Unstructured, want string) (string, string) {
	parents, found, err := unstructured.NestedSlice(obj.Object, "status", "parents")
	if err != nil || !found || len(parents) == 0 {
		return "", ""
	}
	for _, p := range parents {
		pm, ok := p.(map[string]interface{})
		if !ok {
			continue
		}
		conds, _ := pm["conditions"].([]interface{})
		for _, c := range conds {
			m, ok := c.(map[string]interface{})
			if !ok {
				continue
			}
			if m["type"] == want {
				st, _ := m["status"].(string)
				reason, _ := m["reason"].(string)
				return st, reason
			}
		}
	}
	return "", ""
}

func listAll(ctx context.Context, dyn dynamic.Interface, gvr schema.GroupVersionResource) ([]unstructured.Unstructured, error) {
	l, err := dyn.Resource(gvr).Namespace("").List(ctx, metav1.ListOptions{})
	if err != nil {
		return nil, err
	}
	return l.Items, nil
}

func nestedString(obj *unstructured.Unstructured, fields ...string) string {
	v, _, _ := unstructured.NestedString(obj.Object, fields...)
	return v
}

// ── GET /api/v1/istio/overview ──────────────────────────────────────────────

type ClusterOverview struct {
	Name       string `json:"name"`
	Context    string `json:"context"`
	Reachable  bool   `json:"reachable"`
	IstiodVer  string `json:"istiodVersion,omitempty"`
	IstiodOK   bool   `json:"istiodReady"`
	Ztunnel    string `json:"ztunnel,omitempty"` // "1/1"
	ZtunnelOK  bool   `json:"ztunnelReady"`
	CNI        string `json:"cni,omitempty"`
	CNIOK      bool   `json:"cniReady"`
	Network    string `json:"network,omitempty"`
	RootCASHA  string `json:"rootCaSha,omitempty"`
	Namespaces int    `json:"ambientNamespaces"`
	Error      string `json:"error,omitempty"`
}

type OverviewResponse struct {
	Clusters   []ClusterOverview `json:"clusters"`
	SharedRoot bool              `json:"sharedRootCa"`
	Source     string            `json:"source"`
	Notes      []string          `json:"notes,omitempty"`
}

func HandleIstioOverview(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	st := &sourceTracker{}
	out := OverviewResponse{}

	for _, spec := range []struct{ name, kctx string }{
		{"cluster1", ctxCluster1},
		{"cluster2", ctxCluster2},
	} {
		co := ClusterOverview{Name: spec.name, Context: spec.kctx}
		cc, err := k8sclient.ForContext(spec.kctx)
		if err != nil {
			co.Error = err.Error()
			st.fail(spec.name, err)
			out.Clusters = append(out.Clusters, co)
			continue
		}
		co.Reachable = true

		if d, err := cc.Clientset.AppsV1().Deployments("istio-system").Get(ctx, "istiod", metav1.GetOptions{}); err == nil {
			if len(d.Spec.Template.Spec.Containers) > 0 {
				img := d.Spec.Template.Spec.Containers[0].Image
				if i := strings.LastIndex(img, ":"); i >= 0 {
					co.IstiodVer = img[i+1:]
				}
			}
			co.IstiodOK = d.Status.ReadyReplicas >= 1
		}

		for _, ds := range []struct {
			name string
			set  *string
			ok   *bool
		}{
			{"ztunnel", &co.Ztunnel, &co.ZtunnelOK},
			{"istio-cni-node", &co.CNI, &co.CNIOK},
		} {
			if d, err := cc.Clientset.AppsV1().DaemonSets("istio-system").Get(ctx, ds.name, metav1.GetOptions{}); err == nil {
				*ds.set = fmt.Sprintf("%d/%d", d.Status.NumberReady, d.Status.DesiredNumberScheduled)
				*ds.ok = d.Status.NumberReady > 0 && d.Status.NumberReady == d.Status.DesiredNumberScheduled
			}
		}

		// The network label on istio-system is what ztunnel uses to decide
		// whether a peer is cross-network.
		if ns, err := cc.Clientset.CoreV1().Namespaces().Get(ctx, "istio-system", metav1.GetOptions{}); err == nil {
			co.Network = ns.Labels["topology.istio.io/network"]
		}

		// Shared root CA is what makes cross-cluster mTLS possible at all; if
		// these differ, Act 3 cannot work no matter what else is configured.
		if sec, err := cc.Clientset.CoreV1().Secrets("istio-system").Get(ctx, "cacerts", metav1.GetOptions{}); err == nil {
			if root, ok := sec.Data["root-cert.pem"]; ok {
				co.RootCASHA = sha256Fingerprint(root)
			}
		}

		if nsList, err := cc.Clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{
			LabelSelector: "istio.io/dataplane-mode=ambient",
		}); err == nil {
			co.Namespaces = len(nsList.Items)
		}

		st.ok()
		out.Clusters = append(out.Clusters, co)
	}

	if len(out.Clusters) == 2 &&
		out.Clusters[0].RootCASHA != "" &&
		out.Clusters[0].RootCASHA == out.Clusters[1].RootCASHA {
		out.SharedRoot = true
	}
	out.Source = st.String()
	out.Notes = st.notes
	writeJSON(w, out)
}

// ── GET /api/v1/istio/gateways ──────────────────────────────────────────────

type GatewayInfo struct {
	Name       string   `json:"name"`
	Namespace  string   `json:"namespace"`
	Cluster    string   `json:"cluster"`
	Class      string   `json:"class"`
	Address    string   `json:"address,omitempty"`
	Programmed bool     `json:"programmed"`
	Listeners  []string `json:"listeners,omitempty"`
	Act        string   `json:"act,omitempty"`
}

type RouteInfo struct {
	Name      string   `json:"name"`
	Namespace string   `json:"namespace"`
	Cluster   string   `json:"cluster"`
	Parent    string   `json:"parent,omitempty"`
	Hostnames []string `json:"hostnames,omitempty"`
	Accepted  bool     `json:"accepted"`
	Reason    string   `json:"reason,omitempty"`
	Backends  []string `json:"backends,omitempty"`
}

type ListenerSetInfo struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Cluster   string `json:"cluster"`
	Parent    string `json:"parent,omitempty"`
	Accepted  bool   `json:"accepted"`
}

type GatewaysResponse struct {
	Gateways     []GatewayInfo     `json:"gateways"`
	Routes       []RouteInfo       `json:"routes"`
	ListenerSets []ListenerSetInfo `json:"listenerSets"`
	Source       string            `json:"source"`
	Notes        []string          `json:"notes,omitempty"`
}

// gatewayClassAct labels each GatewayClass with the demo act it belongs to, so
// the UI can group all four classes meaningfully instead of listing them flat.
func gatewayClassAct(class string) string {
	switch class {
	case "istio":
		return "Act 1 — north-south"
	case "istio-waypoint":
		return "Act 2 — L7 waypoint"
	case "istio-east-west":
		return "Act 3 — multicluster"
	case "istio-agentgateway":
		return "Act 4 — AI gateway"
	}
	return ""
}

func HandleIstioGateways(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	st := &sourceTracker{}
	out := GatewaysResponse{
		Gateways:     []GatewayInfo{},
		Routes:       []RouteInfo{},
		ListenerSets: []ListenerSetInfo{},
	}

	for _, spec := range []struct{ name, kctx string }{
		{"cluster1", ctxCluster1},
		{"cluster2", ctxCluster2},
	} {
		cc, err := k8sclient.ForContext(spec.kctx)
		if err != nil {
			st.fail(spec.name, err)
			continue
		}

		if items, err := listAll(ctx, cc.Dynamic, gvrGateway); err == nil {
			for i := range items {
				g := &items[i]
				info := GatewayInfo{
					Name:      g.GetName(),
					Namespace: g.GetNamespace(),
					Cluster:   spec.name,
					Class:     nestedString(g, "spec", "gatewayClassName"),
				}
				info.Act = gatewayClassAct(info.Class)
				status, _ := condition(g, "Programmed")
				info.Programmed = status == "True"

				if addrs, found, _ := unstructured.NestedSlice(g.Object, "status", "addresses"); found {
					for _, a := range addrs {
						if am, ok := a.(map[string]interface{}); ok {
							if v, ok := am["value"].(string); ok && info.Address == "" {
								info.Address = v
							}
						}
					}
				}
				if ls, found, _ := unstructured.NestedSlice(g.Object, "spec", "listeners"); found {
					for _, l := range ls {
						if lm, ok := l.(map[string]interface{}); ok {
							name, _ := lm["name"].(string)
							proto, _ := lm["protocol"].(string)
							port, _ := lm["port"].(int64)
							info.Listeners = append(info.Listeners,
								fmt.Sprintf("%s %s/%d", name, proto, port))
						}
					}
				}
				out.Gateways = append(out.Gateways, info)
			}
			st.ok()
		} else {
			st.fail(spec.name+" gateways", err)
		}

		if items, err := listAll(ctx, cc.Dynamic, gvrHTTPRoute); err == nil {
			for i := range items {
				rt := &items[i]
				info := RouteInfo{
					Name:      rt.GetName(),
					Namespace: rt.GetNamespace(),
					Cluster:   spec.name,
				}
				status, reason := routeCondition(rt, "Accepted")
				info.Accepted = status == "True"
				info.Reason = reason

				if hs, found, _ := unstructured.NestedStringSlice(rt.Object, "spec", "hostnames"); found {
					info.Hostnames = hs
				}
				if ps, found, _ := unstructured.NestedSlice(rt.Object, "spec", "parentRefs"); found && len(ps) > 0 {
					if pm, ok := ps[0].(map[string]interface{}); ok {
						pn, _ := pm["name"].(string)
						pns, _ := pm["namespace"].(string)
						if pns != "" {
							info.Parent = pns + "/" + pn
						} else {
							info.Parent = pn
						}
					}
				}
				info.Backends = routeBackends(rt)
				out.Routes = append(out.Routes, info)
			}
		}

		if items, err := listAll(ctx, cc.Dynamic, gvrListenerSet); err == nil {
			for i := range items {
				l := &items[i]
				status, _ := condition(l, "Accepted")
				info := ListenerSetInfo{
					Name:      l.GetName(),
					Namespace: l.GetNamespace(),
					Cluster:   spec.name,
					Accepted:  status == "True",
					Parent:    nestedString(l, "spec", "parentRef", "name"),
				}
				out.ListenerSets = append(out.ListenerSets, info)
			}
		}
	}

	sort.Slice(out.Gateways, func(i, j int) bool {
		return out.Gateways[i].Act < out.Gateways[j].Act
	})
	out.Source = st.String()
	out.Notes = st.notes
	writeJSON(w, out)
}

func routeBackends(rt *unstructured.Unstructured) []string {
	var backends []string
	rules, found, _ := unstructured.NestedSlice(rt.Object, "spec", "rules")
	if !found {
		return backends
	}
	for _, r := range rules {
		rm, ok := r.(map[string]interface{})
		if !ok {
			continue
		}
		brs, _ := rm["backendRefs"].([]interface{})
		for _, b := range brs {
			bm, ok := b.(map[string]interface{})
			if !ok {
				continue
			}
			name, _ := bm["name"].(string)
			if weight, ok := bm["weight"].(int64); ok {
				backends = append(backends, fmt.Sprintf("%s (%d)", name, weight))
			} else if name != "" {
				backends = append(backends, name)
			}
		}
	}
	return backends
}

// ── GET /api/v1/istio/waypoint ──────────────────────────────────────────────

type WaypointPod struct {
	Name       string   `json:"name"`
	Containers []string `json:"containers"`
	Ready      bool     `json:"ready"`
}

type AuthzRule struct {
	Name       string   `json:"name"`
	Namespace  string   `json:"namespace"`
	Action     string   `json:"action"`
	TargetKind string   `json:"targetKind,omitempty"`
	TargetName string   `json:"targetName,omitempty"`
	Principals []string `json:"principals,omitempty"`
	Methods    []string `json:"methods,omitempty"`
	Paths      []string `json:"paths,omitempty"`
}

type WaypointResponse struct {
	Enrolled     []string      `json:"enrolledNamespaces"`
	Programmed   bool          `json:"waypointProgrammed"`
	WaypointName string        `json:"waypointName,omitempty"`
	Policies     []AuthzRule   `json:"policies"`
	Pods         []WaypointPod `json:"pods"`
	SidecarFree  bool          `json:"sidecarFree"`
	Source       string        `json:"source"`
	Notes        []string      `json:"notes,omitempty"`
}

// HandleIstioWaypoint reports the waypoint plus the evidence that makes ambient
// interesting: the application pods carry NO istio-proxy sidecar, yet L7 policy
// is still enforced. SidecarFree is computed from real container lists rather
// than asserted.
func HandleIstioWaypoint(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	st := &sourceTracker{}
	out := WaypointResponse{
		Enrolled:    []string{},
		Policies:    []AuthzRule{},
		Pods:        []WaypointPod{},
		SidecarFree: true,
	}

	cc, err := k8sclient.ForContext(ctxCluster1)
	if err != nil {
		st.fail("cluster1", err)
		out.Source = st.String()
		out.Notes = st.notes
		writeJSON(w, out)
		return
	}

	if nsList, err := cc.Clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{
		LabelSelector: "istio.io/dataplane-mode=ambient",
	}); err == nil {
		for _, ns := range nsList.Items {
			out.Enrolled = append(out.Enrolled, ns.Name)
		}
		st.ok()
	} else {
		st.fail("ambient namespaces", err)
	}

	if items, err := listAll(ctx, cc.Dynamic, gvrGateway); err == nil {
		for i := range items {
			g := &items[i]
			if nestedString(g, "spec", "gatewayClassName") != "istio-waypoint" {
				continue
			}
			out.WaypointName = g.GetNamespace() + "/" + g.GetName()
			status, _ := condition(g, "Programmed")
			out.Programmed = status == "True"
		}
	}

	if items, err := listAll(ctx, cc.Dynamic, gvrAuthorizationPolicy); err == nil {
		for i := range items {
			out.Policies = append(out.Policies, parseAuthzPolicy(&items[i]))
		}
		st.ok()
	} else {
		st.fail("authorization policies", err)
	}

	// Container lists for the workloads themselves. An ambient pod has exactly
	// its own container(s) and no istio-proxy; the waypoint runs separately.
	if pods, err := cc.Clientset.CoreV1().Pods(nsDemoApps).List(ctx, metav1.ListOptions{
		LabelSelector: "app=echo",
	}); err == nil {
		for _, p := range pods.Items {
			wp := WaypointPod{Name: p.Name}
			for _, c := range p.Spec.Containers {
				wp.Containers = append(wp.Containers, c.Name)
				if c.Name == "istio-proxy" {
					out.SidecarFree = false
				}
			}
			for _, cs := range p.Status.ContainerStatuses {
				wp.Ready = cs.Ready
			}
			out.Pods = append(out.Pods, wp)
		}
		st.ok()
	} else {
		st.fail("demo-apps pods", err)
	}

	out.Source = st.String()
	out.Notes = st.notes
	writeJSON(w, out)
}

func parseAuthzPolicy(p *unstructured.Unstructured) AuthzRule {
	ar := AuthzRule{
		Name:      p.GetName(),
		Namespace: p.GetNamespace(),
		Action:    nestedString(p, "spec", "action"),
	}
	// targetRefs (attached to the waypoint Gateway) vs selector (enforced by
	// ztunnel at L4) is the distinction that decides whether L7 rules apply at
	// all, so surface which one this policy uses.
	if trs, found, _ := unstructured.NestedSlice(p.Object, "spec", "targetRefs"); found && len(trs) > 0 {
		if tm, ok := trs[0].(map[string]interface{}); ok {
			ar.TargetKind, _ = tm["kind"].(string)
			ar.TargetName, _ = tm["name"].(string)
		}
	}
	rules, found, _ := unstructured.NestedSlice(p.Object, "spec", "rules")
	if !found {
		return ar
	}
	for _, r := range rules {
		rm, ok := r.(map[string]interface{})
		if !ok {
			continue
		}
		if froms, ok := rm["from"].([]interface{}); ok {
			for _, f := range froms {
				fm, _ := f.(map[string]interface{})
				src, _ := fm["source"].(map[string]interface{})
				if ps, ok := src["principals"].([]interface{}); ok {
					for _, pr := range ps {
						if s, ok := pr.(string); ok {
							ar.Principals = append(ar.Principals, s)
						}
					}
				}
			}
		}
		if tos, ok := rm["to"].([]interface{}); ok {
			for _, t := range tos {
				tm, _ := t.(map[string]interface{})
				op, _ := tm["operation"].(map[string]interface{})
				for _, key := range []string{"methods", "paths"} {
					vals, _ := op[key].([]interface{})
					for _, v := range vals {
						s, ok := v.(string)
						if !ok {
							continue
						}
						if key == "methods" {
							ar.Methods = append(ar.Methods, s)
						} else {
							ar.Paths = append(ar.Paths, s)
						}
					}
				}
			}
		}
	}
	return ar
}

// ── GET /api/v1/istio/multicluster ──────────────────────────────────────────

type MCCluster struct {
	Name          string `json:"name"`
	Network       string `json:"network,omitempty"`
	EastWestIP    string `json:"eastWestIp,omitempty"`
	EastWestOK    bool   `json:"eastWestProgrammed"`
	RemoteSecret  string `json:"remoteSecret,omitempty"`
	GlobalSvcs    int    `json:"globalServices"`
	LocalEndpoint int    `json:"localEndpoints"`
	Reachable     bool   `json:"reachable"`
}

type MulticlusterResponse struct {
	Clusters   []MCCluster `json:"clusters"`
	SharedRoot bool        `json:"sharedRootCa"`
	Federated  bool        `json:"federated"`
	Source     string      `json:"source"`
	Notes      []string    `json:"notes,omitempty"`
}

func HandleIstioMulticluster(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	st := &sourceTracker{}
	out := MulticlusterResponse{Clusters: []MCCluster{}}
	var roots []string

	for _, spec := range []struct{ name, kctx string }{
		{"cluster1", ctxCluster1},
		{"cluster2", ctxCluster2},
	} {
		mc := MCCluster{Name: spec.name}
		cc, err := k8sclient.ForContext(spec.kctx)
		if err != nil {
			st.fail(spec.name, err)
			out.Clusters = append(out.Clusters, mc)
			continue
		}
		mc.Reachable = true

		if ns, err := cc.Clientset.CoreV1().Namespaces().Get(ctx, "istio-system", metav1.GetOptions{}); err == nil {
			mc.Network = ns.Labels["topology.istio.io/network"]
		}
		if sec, err := cc.Clientset.CoreV1().Secrets("istio-system").Get(ctx, "cacerts", metav1.GetOptions{}); err == nil {
			if root, ok := sec.Data["root-cert.pem"]; ok {
				roots = append(roots, sha256Fingerprint(root))
			}
		}

		if items, err := listAll(ctx, cc.Dynamic, gvrGateway); err == nil {
			for i := range items {
				g := &items[i]
				if nestedString(g, "spec", "gatewayClassName") != "istio-east-west" {
					continue
				}
				status, _ := condition(g, "Programmed")
				mc.EastWestOK = status == "True"
				if addrs, found, _ := unstructured.NestedSlice(g.Object, "status", "addresses"); found && len(addrs) > 0 {
					if am, ok := addrs[0].(map[string]interface{}); ok {
						mc.EastWestIP, _ = am["value"].(string)
					}
				}
			}
			st.ok()
		} else {
			st.fail(spec.name+" gateways", err)
		}

		// A remote secret is how each istiod learns to read its peer's
		// endpoints. Its ABSENCE means no federation regardless of gateways.
		if secs, err := cc.Clientset.CoreV1().Secrets("istio-system").List(ctx, metav1.ListOptions{
			LabelSelector: "istio/multiCluster=true",
		}); err == nil && len(secs.Items) > 0 {
			names := make([]string, 0, len(secs.Items))
			for _, s := range secs.Items {
				names = append(names, s.Name)
			}
			mc.RemoteSecret = strings.Join(names, ", ")
		}

		// Services explicitly marked global, and how many local endpoints back
		// them right now — the number that drops to zero during failover.
		if svcs, err := cc.Clientset.CoreV1().Services(nsDemoApps).List(ctx, metav1.ListOptions{
			LabelSelector: "istio.io/global=true",
		}); err == nil {
			mc.GlobalSvcs = len(svcs.Items)
		}
		if pods, err := cc.Clientset.CoreV1().Pods(nsDemoApps).List(ctx, metav1.ListOptions{
			LabelSelector: "app=" + demoService,
		}); err == nil {
			for _, p := range pods.Items {
				if p.DeletionTimestamp == nil && p.Status.Phase == "Running" {
					mc.LocalEndpoint++
				}
			}
		}

		out.Clusters = append(out.Clusters, mc)
	}

	if len(roots) == 2 && roots[0] == roots[1] {
		out.SharedRoot = true
	}
	out.Federated = out.SharedRoot &&
		len(out.Clusters) == 2 &&
		out.Clusters[0].EastWestOK && out.Clusters[1].EastWestOK &&
		out.Clusters[0].RemoteSecret != "" && out.Clusters[1].RemoteSecret != ""

	out.Source = st.String()
	out.Notes = st.notes
	writeJSON(w, out)
}

// ── GET /api/v1/istio/ai-gateway ────────────────────────────────────────────

type AIGatewayResponse struct {
	Present     bool     `json:"present"`
	ClassExists bool     `json:"classExists"`
	Address     string   `json:"address,omitempty"`
	Programmed  bool     `json:"programmed"`
	Models      []string `json:"models"`
	Backend     string   `json:"backend,omitempty"`
	Source      string   `json:"source"`
	Notes       []string `json:"notes,omitempty"`
}

func HandleIstioAIGateway(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()

	st := &sourceTracker{}
	out := AIGatewayResponse{Models: []string{}}

	cc, err := k8sclient.ForContext(ctxCluster1)
	if err != nil {
		st.fail("cluster1", err)
		out.Source = st.String()
		out.Notes = st.notes
		writeJSON(w, out)
		return
	}

	if items, err := listAll(ctx, cc.Dynamic, gvrGateway); err == nil {
		for i := range items {
			g := &items[i]
			if nestedString(g, "spec", "gatewayClassName") != "istio-agentgateway" {
				continue
			}
			out.Present = true
			out.ClassExists = true
			status, _ := condition(g, "Programmed")
			out.Programmed = status == "True"
			if addrs, found, _ := unstructured.NestedSlice(g.Object, "status", "addresses"); found && len(addrs) > 0 {
				if am, ok := addrs[0].(map[string]interface{}); ok {
					out.Address, _ = am["value"].(string)
				}
			}
		}
		st.ok()
	} else {
		st.fail("cluster1 gateways", err)
	}

	// Fetch the model list THROUGH the gateway, not from Ollama directly —
	// that is what proves the data path works rather than just the config.
	addr := out.Address
	if addr == "" {
		addr = aiGatewayIP
	}
	if models, err := fetchOllamaModels(ctx, "http://"+addr+"/api/tags"); err == nil {
		out.Models = models
		out.Backend = "host Ollama via " + addr
		st.ok()
	} else {
		st.fail("model list via gateway", err)
	}

	out.Source = st.String()
	out.Notes = st.notes
	writeJSON(w, out)
}

// ── GET /api/v1/istio/observability ─────────────────────────────────────────

type ObservabilityResponse struct {
	PrometheusUp bool     `json:"prometheusUp"`
	KialiUp      bool     `json:"kialiUp"`
	KialiURL     string   `json:"kialiUrl"`
	RequestSerie int      `json:"requestSeries"`
	Source       string   `json:"source"`
	Notes        []string `json:"notes,omitempty"`
}

func HandleIstioObservability(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 20*time.Second)
	defer cancel()

	st := &sourceTracker{}
	out := ObservabilityResponse{KialiURL: kialiURL}

	cc, err := k8sclient.ForContext(ctxCluster1)
	if err != nil {
		st.fail("cluster1", err)
		out.Source = st.String()
		out.Notes = st.notes
		writeJSON(w, out)
		return
	}

	for _, d := range []struct {
		name string
		flag *bool
	}{
		{"prometheus", &out.PrometheusUp},
		{"kiali", &out.KialiUp},
	} {
		if dep, err := cc.Clientset.AppsV1().Deployments("istio-system").Get(ctx, d.name, metav1.GetOptions{}); err == nil {
			*d.flag = dep.Status.ReadyReplicas >= 1
			st.ok()
		} else {
			st.fail(d.name, err)
		}
	}

	// Series count is the only honest "is telemetry actually flowing" signal —
	// a Ready Prometheus with zero series means the mesh is not reporting.
	if out.PrometheusUp {
		if n, err := prometheusSeriesCount(ctx, "count(istio_requests_total)"); err == nil {
			out.RequestSerie = n
			st.ok()
		} else {
			st.fail("prometheus query", err)
		}
	}

	out.Source = st.String()
	out.Notes = st.notes
	writeJSON(w, out)
}
