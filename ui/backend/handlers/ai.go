package handlers

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"
)

type ChatRequest struct {
	Message string `json:"message"`
}

// POST /api/ai/chat
func HandleAIChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req ChatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	if req.Message == "" {
		writeError(w, http.StatusBadRequest, "message is required")
		return
	}

	// Set SSE headers
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming not supported")
		return
	}

	response := generateMockResponse(req.Message)
	words := strings.Fields(response)

	for i, word := range words {
		if r.Context().Err() != nil {
			return
		}

		token := word
		if i < len(words)-1 {
			token += " "
		}

		fmt.Fprintf(w, "data: %s\n\n", jsonEscape(token))
		flusher.Flush()
		time.Sleep(30 * time.Millisecond)
	}

	// Send done event
	fmt.Fprintf(w, "data: [DONE]\n\n")
	flusher.Flush()
}

func jsonEscape(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		log.Printf("Error marshaling token: %v", err)
		return s
	}
	// Remove surrounding quotes from JSON string
	return string(b[1 : len(b)-1])
}

func generateMockResponse(message string) string {
	msg := strings.ToLower(message)

	switch {
	case strings.Contains(msg, "pod") && (strings.Contains(msg, "running") || strings.Contains(msg, "show") || strings.Contains(msg, "list")):
		return "Here's a summary of running pods in your cluster:\n\n" +
			"**kube-system namespace:**\n" +
			"- coredns-5dd5756b68-abcde (Running, 0 restarts)\n" +
			"- etcd-control-plane (Running, 0 restarts)\n" +
			"- kube-apiserver-control-plane (Running, 0 restarts)\n" +
			"- kube-controller-manager (Running, 0 restarts)\n" +
			"- kube-scheduler (Running, 0 restarts)\n\n" +
			"All system pods appear healthy with zero restarts. You can view detailed pod information in the Pods section of the dashboard."

	case strings.Contains(msg, "vm") || strings.Contains(msg, "virtual machine"):
		if strings.Contains(msg, "create") || strings.Contains(msg, "start") || strings.Contains(msg, "launch") {
			return "To create a new KubeVirt virtual machine, you would typically apply a VirtualMachine manifest. " +
				"Here's a basic example:\n\n" +
				"```yaml\napiVersion: kubevirt.io/v1\nkind: VirtualMachine\nmetadata:\n  name: my-vm\nspec:\n  running: true\n  template:\n    spec:\n      domain:\n        cpu:\n          cores: 2\n        memory:\n          guest: 4Gi\n```\n\n" +
				"You can apply this with `kubectl apply -f vm.yaml`. Check the Virtual Machines tab to monitor its status."
		}
		return "Here's the status of KubeVirt virtual machines in your cluster:\n\n" +
			"The Virtual Machines page shows all VMs managed by KubeVirt. Each VM displays its status (Running/Stopped), " +
			"allocated CPU cores, memory, the node it's scheduled on, and its IP address.\n\n" +
			"You can filter VMs by namespace using the namespace selector. " +
			"If no VMs appear, ensure that KubeVirt is properly installed in your cluster."

	case strings.Contains(msg, "cluster") && (strings.Contains(msg, "health") || strings.Contains(msg, "status")):
		return "Let me check the cluster health for you.\n\n" +
			"**Cluster Overview:**\n" +
			"The cluster status dashboard provides a real-time view of your Kubernetes cluster. " +
			"It shows the total number of nodes and their readiness state, pod distribution across different phases " +
			"(Running, Pending, Failed), virtual machine counts, and namespace totals.\n\n" +
			"**Key Metrics to Watch:**\n" +
			"- Node readiness: All nodes should show Ready status\n" +
			"- Pod failures: Check for pods in Failed or CrashLoopBackOff state\n" +
			"- Pending pods: May indicate resource constraints\n\n" +
			"Check the Cluster Status section at the top of the dashboard for current numbers."

	case strings.Contains(msg, "node"):
		return "Your Kubernetes nodes are the worker machines in your cluster.\n\n" +
			"**Node Information:**\n" +
			"Each node shows its status (Ready/NotReady), roles (control-plane, worker), " +
			"allocatable CPU and memory resources, age, and kubelet version.\n\n" +
			"**Tips:**\n" +
			"- Nodes with NotReady status may have networking issues or resource pressure\n" +
			"- Check node conditions for details: `kubectl describe node <name>`\n" +
			"- Monitor CPU and memory to ensure adequate capacity for workloads\n\n" +
			"View the Nodes tab in the dashboard for the complete list."

	case strings.Contains(msg, "event"):
		return "Kubernetes events provide insights into what's happening in your cluster.\n\n" +
			"**Event Types:**\n" +
			"- **Normal**: Routine operations like pod scheduling and image pulling\n" +
			"- **Warning**: Issues like failed scheduling, unhealthy probes, or OOM kills\n\n" +
			"**Common Events:**\n" +
			"- Scheduled: Pod assigned to a node\n" +
			"- Pulling/Pulled: Container image operations\n" +
			"- Created/Started: Container lifecycle\n" +
			"- Killing: Pod termination\n" +
			"- FailedScheduling: Resource constraints\n\n" +
			"Check the Events tab and filter by namespace to investigate issues."

	case strings.Contains(msg, "namespace"):
		return "Namespaces provide a way to divide cluster resources between multiple users or teams.\n\n" +
			"**Default Namespaces:**\n" +
			"- `default`: The default namespace for objects with no namespace\n" +
			"- `kube-system`: System components created by Kubernetes\n" +
			"- `kube-public`: Readable by all users, used for public resources\n" +
			"- `kube-node-lease`: Node heartbeat leases\n\n" +
			"Use the namespace filter throughout the dashboard to scope your view to specific namespaces."

	case strings.Contains(msg, "help") || strings.Contains(msg, "what can you"):
		return "I can help you understand and manage your Kubernetes cluster. Here are some things you can ask me:\n\n" +
			"- **\"Show running pods\"** - Get a summary of pod status\n" +
			"- **\"List VMs\"** - View virtual machine information\n" +
			"- **\"Cluster health\"** - Check overall cluster status\n" +
			"- **\"Show nodes\"** - View node details\n" +
			"- **\"List events\"** - See recent cluster events\n" +
			"- **\"Explain namespaces\"** - Learn about namespace usage\n\n" +
			"I can also answer general Kubernetes questions and provide troubleshooting guidance."

	default:
		return "I understand you're asking about: \"" + message + "\"\n\n" +
			"I'm an AI assistant for this Kubernetes dashboard. I can help with:\n\n" +
			"- Viewing and understanding cluster resources (pods, nodes, VMs)\n" +
			"- Interpreting cluster health and status\n" +
			"- Providing Kubernetes best practices and guidance\n" +
			"- Troubleshooting common issues\n\n" +
			"Try asking me about specific resources like \"show running pods\" or \"cluster health\" for detailed information."
	}
}
