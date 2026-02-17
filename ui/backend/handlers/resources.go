package handlers

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	k8sclient "kubeui/backend/k8s"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// Response types matching the frontend TypeScript interfaces

type KubeNode struct {
	Name           string `json:"name"`
	Status         string `json:"status"`
	Roles          string `json:"roles"`
	CPU            string `json:"cpu"`
	Memory         string `json:"memory"`
	Age            string `json:"age"`
	KubeletVersion string `json:"kubeletVersion"`
}

type Pod struct {
	Name            string `json:"name"`
	Namespace       string `json:"namespace"`
	Status          string `json:"status"`
	Node            string `json:"node"`
	Restarts        int    `json:"restarts"`
	Age             string `json:"age"`
	Containers      int    `json:"containers"`
	ReadyContainers int    `json:"readyContainers"`
}

type VirtualMachine struct {
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
	Status    string `json:"status"`
	CPU       int    `json:"cpu"`
	Memory    string `json:"memory"`
	Node      string `json:"node"`
	Age       string `json:"age"`
	IPAddress string `json:"ipAddress"`
}

type KubeEvent struct {
	Type           string `json:"type"`
	Reason         string `json:"reason"`
	Message        string `json:"message"`
	InvolvedObject string `json:"involvedObject"`
	Namespace      string `json:"namespace"`
	Age            string `json:"age"`
	Count          int    `json:"count"`
}

type ClusterStatus struct {
	Nodes      NodeStatus `json:"nodes"`
	Pods       PodStatus  `json:"pods"`
	VMs        VMStatus   `json:"vms"`
	Namespaces int        `json:"namespaces"`
}

type NodeStatus struct {
	Total int `json:"total"`
	Ready int `json:"ready"`
}

type PodStatus struct {
	Total   int `json:"total"`
	Running int `json:"running"`
	Pending int `json:"pending"`
	Failed  int `json:"failed"`
}

type VMStatus struct {
	Total   int `json:"total"`
	Running int `json:"running"`
	Stopped int `json:"stopped"`
}

type Namespace struct {
	Name   string `json:"name"`
	Status string `json:"status"`
}

func writeJSON(w http.ResponseWriter, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(data); err != nil {
		log.Printf("Error encoding JSON response: %v", err)
	}
}

func writeError(w http.ResponseWriter, code int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": message})
}

func formatAge(t time.Time) string {
	d := time.Since(t)
	if d.Hours() >= 24*365 {
		return fmt.Sprintf("%dy", int(d.Hours()/(24*365)))
	}
	if d.Hours() >= 24 {
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
	if d.Hours() >= 1 {
		return fmt.Sprintf("%dh", int(d.Hours()))
	}
	if d.Minutes() >= 1 {
		return fmt.Sprintf("%dm", int(d.Minutes()))
	}
	return fmt.Sprintf("%ds", int(d.Seconds()))
}

// GET /api/v1/nodes
func HandleNodes(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	nodeList, err := k8sclient.Clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Error listing nodes: %v", err)
		writeJSON(w, []KubeNode{})
		return
	}

	nodes := make([]KubeNode, 0, len(nodeList.Items))
	for _, n := range nodeList.Items {
		status := "NotReady"
		for _, cond := range n.Status.Conditions {
			if cond.Type == "Ready" && cond.Status == "True" {
				status = "Ready"
				break
			}
		}

		roles := []string{}
		for label := range n.Labels {
			if strings.HasPrefix(label, "node-role.kubernetes.io/") {
				role := strings.TrimPrefix(label, "node-role.kubernetes.io/")
				if role != "" {
					roles = append(roles, role)
				}
			}
		}
		roleStr := strings.Join(roles, ",")
		if roleStr == "" {
			roleStr = "<none>"
		}

		cpu := n.Status.Allocatable.Cpu().String()
		memory := n.Status.Allocatable.Memory().String()

		nodes = append(nodes, KubeNode{
			Name:           n.Name,
			Status:         status,
			Roles:          roleStr,
			CPU:            cpu,
			Memory:         memory,
			Age:            formatAge(n.CreationTimestamp.Time),
			KubeletVersion: n.Status.NodeInfo.KubeletVersion,
		})
	}

	writeJSON(w, nodes)
}

// GET /api/v1/pods?namespace=X
func HandlePods(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	namespace := r.URL.Query().Get("namespace")
	if namespace == "" {
		namespace = ""
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	podList, err := k8sclient.Clientset.CoreV1().Pods(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Error listing pods: %v", err)
		writeJSON(w, []Pod{})
		return
	}

	pods := make([]Pod, 0, len(podList.Items))
	for _, p := range podList.Items {
		totalContainers := len(p.Spec.Containers)
		readyContainers := 0
		restarts := 0
		for _, cs := range p.Status.ContainerStatuses {
			if cs.Ready {
				readyContainers++
			}
			restarts += int(cs.RestartCount)
		}

		status := string(p.Status.Phase)
		// Check for more specific container status reasons
		for _, cs := range p.Status.ContainerStatuses {
			if cs.State.Waiting != nil && cs.State.Waiting.Reason != "" {
				status = cs.State.Waiting.Reason
				break
			}
			if cs.State.Terminated != nil && cs.State.Terminated.Reason != "" {
				status = cs.State.Terminated.Reason
				break
			}
		}

		pods = append(pods, Pod{
			Name:            p.Name,
			Namespace:       p.Namespace,
			Status:          status,
			Node:            p.Spec.NodeName,
			Restarts:        restarts,
			Age:             formatAge(p.CreationTimestamp.Time),
			Containers:      totalContainers,
			ReadyContainers: readyContainers,
		})
	}

	writeJSON(w, pods)
}

// GET /api/v1/namespaces
func HandleNamespaces(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	nsList, err := k8sclient.Clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Error listing namespaces: %v", err)
		writeJSON(w, []Namespace{})
		return
	}

	namespaces := make([]Namespace, 0, len(nsList.Items))
	for _, ns := range nsList.Items {
		namespaces = append(namespaces, Namespace{
			Name:   ns.Name,
			Status: string(ns.Status.Phase),
		})
	}

	writeJSON(w, namespaces)
}

// GET /api/v1/events?namespace=X
func HandleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	namespace := r.URL.Query().Get("namespace")

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	eventList, err := k8sclient.Clientset.CoreV1().Events(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Error listing events: %v", err)
		writeJSON(w, []KubeEvent{})
		return
	}

	events := make([]KubeEvent, 0, len(eventList.Items))
	for _, e := range eventList.Items {
		involvedObj := fmt.Sprintf("%s/%s", e.InvolvedObject.Kind, e.InvolvedObject.Name)

		eventTime := e.LastTimestamp.Time
		if eventTime.IsZero() {
			eventTime = e.CreationTimestamp.Time
		}

		events = append(events, KubeEvent{
			Type:           e.Type,
			Reason:         e.Reason,
			Message:        e.Message,
			InvolvedObject: involvedObj,
			Namespace:      e.Namespace,
			Age:            formatAge(eventTime),
			Count:          int(e.Count),
		})
	}

	writeJSON(w, events)
}

var vmGVR = schema.GroupVersionResource{
	Group:    "kubevirt.io",
	Version:  "v1",
	Resource: "virtualmachines",
}

var vmiGVR = schema.GroupVersionResource{
	Group:    "kubevirt.io",
	Version:  "v1",
	Resource: "virtualmachineinstances",
}

// GET /api/v1/virtualmachines?namespace=X
func HandleVirtualMachines(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	namespace := r.URL.Query().Get("namespace")

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	vms := listVirtualMachines(ctx, namespace)
	writeJSON(w, vms)
}

// GET /api/v1/virtualmachines/:namespace/:name
func HandleVirtualMachine(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// Parse path: /api/v1/virtualmachines/{namespace}/{name}
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/virtualmachines/")
	parts := strings.SplitN(path, "/", 2)
	if len(parts) != 2 || parts[0] == "" || parts[1] == "" {
		writeError(w, http.StatusBadRequest, "namespace and name are required")
		return
	}
	namespace := parts[0]
	name := parts[1]

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	// Get the VM
	vmObj, err := k8sclient.DynamicClient.Resource(vmGVR).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	if err != nil {
		log.Printf("Error getting VM %s/%s: %v", namespace, name, err)
		writeError(w, http.StatusNotFound, "virtual machine not found")
		return
	}

	vm := parseVM(vmObj.Object)
	vm.Namespace = namespace

	// Try to get VMI for runtime info
	vmiObj, err := k8sclient.DynamicClient.Resource(vmiGVR).Namespace(namespace).Get(ctx, name, metav1.GetOptions{})
	if err == nil {
		enrichVMFromVMI(&vm, vmiObj.Object)
	}

	writeJSON(w, vm)
}

func listVirtualMachines(ctx context.Context, namespace string) []VirtualMachine {
	vmList, err := k8sclient.DynamicClient.Resource(vmGVR).Namespace(namespace).List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Error listing VMs (CRD may not exist): %v", err)
		return []VirtualMachine{}
	}

	// Build a map of VMIs for runtime info
	vmiMap := make(map[string]map[string]interface{})
	vmiList, err := k8sclient.DynamicClient.Resource(vmiGVR).Namespace(namespace).List(ctx, metav1.ListOptions{})
	if err == nil {
		for _, vmi := range vmiList.Items {
			key := fmt.Sprintf("%s/%s", vmi.GetNamespace(), vmi.GetName())
			vmiMap[key] = vmi.Object
		}
	}

	vms := make([]VirtualMachine, 0, len(vmList.Items))
	for _, item := range vmList.Items {
		vm := parseVM(item.Object)
		vm.Namespace = item.GetNamespace()

		key := fmt.Sprintf("%s/%s", vm.Namespace, vm.Name)
		if vmiObj, ok := vmiMap[key]; ok {
			enrichVMFromVMI(&vm, vmiObj)
		}

		vms = append(vms, vm)
	}

	return vms
}

func parseVM(obj map[string]interface{}) VirtualMachine {
	vm := VirtualMachine{}

	if metadata, ok := obj["metadata"].(map[string]interface{}); ok {
		if name, ok := metadata["name"].(string); ok {
			vm.Name = name
		}
		if ns, ok := metadata["namespace"].(string); ok {
			vm.Namespace = ns
		}
		if ts, ok := metadata["creationTimestamp"].(string); ok {
			if t, err := time.Parse(time.RFC3339, ts); err == nil {
				vm.Age = formatAge(t)
			}
		}
	}

	// Parse spec for CPU and memory
	if spec, ok := obj["spec"].(map[string]interface{}); ok {
		if template, ok := spec["template"].(map[string]interface{}); ok {
			if tSpec, ok := template["spec"].(map[string]interface{}); ok {
				if domain, ok := tSpec["domain"].(map[string]interface{}); ok {
					// CPU
					if cpu, ok := domain["cpu"].(map[string]interface{}); ok {
						if cores, ok := cpu["cores"].(int64); ok {
							vm.CPU = int(cores)
						} else if cores, ok := cpu["cores"].(float64); ok {
							vm.CPU = int(cores)
						}
					}
					// Memory
					if resources, ok := domain["resources"].(map[string]interface{}); ok {
						if requests, ok := resources["requests"].(map[string]interface{}); ok {
							if mem, ok := requests["memory"].(string); ok {
								vm.Memory = mem
							}
						}
					}
					if vm.Memory == "" {
						if memory, ok := domain["memory"].(map[string]interface{}); ok {
							if guest, ok := memory["guest"].(string); ok {
								vm.Memory = guest
							}
						}
					}
				}
			}
		}
	}

	// Parse status
	vm.Status = "Stopped"
	if status, ok := obj["status"].(map[string]interface{}); ok {
		if ready, ok := status["ready"].(bool); ok && ready {
			vm.Status = "Running"
		}
		if printableStatus, ok := status["printableStatus"].(string); ok {
			vm.Status = printableStatus
		}
	}

	if vm.CPU == 0 {
		vm.CPU = 1
	}
	if vm.Memory == "" {
		vm.Memory = "unknown"
	}

	return vm
}

func enrichVMFromVMI(vm *VirtualMachine, vmiObj map[string]interface{}) {
	if status, ok := vmiObj["status"].(map[string]interface{}); ok {
		if nodeName, ok := status["nodeName"].(string); ok {
			vm.Node = nodeName
		}
		if interfaces, ok := status["interfaces"].([]interface{}); ok && len(interfaces) > 0 {
			if iface, ok := interfaces[0].(map[string]interface{}); ok {
				if ip, ok := iface["ipAddress"].(string); ok {
					vm.IPAddress = ip
				}
			}
		}
		if phase, ok := status["phase"].(string); ok {
			vm.Status = phase
		}
	}
}

// GET /api/v1/cluster/status
func HandleClusterStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 15*time.Second)
	defer cancel()

	status := ClusterStatus{}

	// Nodes
	nodeList, err := k8sclient.Clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Error listing nodes for cluster status: %v", err)
	} else {
		status.Nodes.Total = len(nodeList.Items)
		for _, n := range nodeList.Items {
			for _, cond := range n.Status.Conditions {
				if cond.Type == "Ready" && cond.Status == "True" {
					status.Nodes.Ready++
					break
				}
			}
		}
	}

	// Pods
	podList, err := k8sclient.Clientset.CoreV1().Pods("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Error listing pods for cluster status: %v", err)
	} else {
		status.Pods.Total = len(podList.Items)
		for _, p := range podList.Items {
			switch p.Status.Phase {
			case "Running":
				status.Pods.Running++
			case "Pending":
				status.Pods.Pending++
			case "Failed":
				status.Pods.Failed++
			}
		}
	}

	// Namespaces
	nsList, err := k8sclient.Clientset.CoreV1().Namespaces().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Error listing namespaces for cluster status: %v", err)
	} else {
		status.Namespaces = len(nsList.Items)
	}

	// VMs
	vmList, err := k8sclient.DynamicClient.Resource(vmGVR).Namespace("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("KubeVirt VMs not available: %v", err)
	} else {
		status.VMs.Total = len(vmList.Items)
		for _, item := range vmList.Items {
			obj := item.Object
			if s, ok := obj["status"].(map[string]interface{}); ok {
				if ready, ok := s["ready"].(bool); ok && ready {
					status.VMs.Running++
				} else {
					status.VMs.Stopped++
				}
			} else {
				status.VMs.Stopped++
			}
		}
	}

	writeJSON(w, status)
}
