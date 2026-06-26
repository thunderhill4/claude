package handlers

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	k8sclient "kubeui/backend/k8s"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// ChatRequest is the incoming request from the frontend.
// Accepts either single-shot {message} or multi-turn {messages:[{role,content}...]}.
type ChatRequest struct {
	Message  string       `json:"message,omitempty"`
	Messages []oaiMessage `json:"messages,omitempty"`
	Agent    string       `json:"agent,omitempty"`
}

// OpenAI-compatible chat completions types — matches Sympozium's serving-mode API.
type oaiChatRequest struct {
	Model    string       `json:"model"`
	Stream   bool         `json:"stream"`
	Messages []oaiMessage `json:"messages"`
}

type oaiMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type oaiStreamChunk struct {
	Choices []oaiChoice `json:"choices"`
}

type oaiChoice struct {
	Delta        oaiDelta `json:"delta"`
	FinishReason *string  `json:"finish_reason"`
}

type oaiDelta struct {
	Content string `json:"content"`
}

// Envelope is the typed SSE payload sent to the frontend in AI mode.
// Each `data:` line is one Envelope JSON.
type Envelope struct {
	Type     string    `json:"type"`               // text | proposal | tool_step | error | done
	Text     string    `json:"text,omitempty"`     // type=text
	Proposal *Proposal `json:"proposal,omitempty"` // type=proposal
	Step     *LogEntry `json:"step,omitempty"`     // type=tool_step (deploy LogEntry)
	Error    string    `json:"error,omitempty"`    // type=error
}

// Proposal is a structured action the agent suggests; user confirms via /api/ai/action.
type Proposal struct {
	ID      string `json:"id"`
	Action  string `json:"action"`            // e.g. "deploy_target_cluster"
	Profile string `json:"profile,omitempty"` // for deploy_target_cluster: "lite" | "full"
	Reason  string `json:"reason,omitempty"`
}

// allowedActions is the whitelist of actions the action endpoint will execute.
// Keeping this tight: any new agent-driven action must be added explicitly.
var allowedActions = map[string]bool{
	"deploy_target_cluster": true,
}

var sympoziumInstanceGVR = schema.GroupVersionResource{
	Group:    "sympozium.ai",
	Version:  "v1alpha1",
	Resource: "sympoziuminstances",
}

func sympoziumNamespace() string {
	if ns := os.Getenv("SYMPOZIUM_NAMESPACE"); ns != "" {
		return ns
	}
	return "sympozium-system"
}

func getDefaultAgent() string {
	if name := os.Getenv("SYMPOZIUM_DEFAULT_AGENT"); name != "" {
		return name
	}
	return "cluster2-agent"
}

// getSympoziumAgentURL returns the base URL (with trailing slash) for the
// named agent's OpenAI-compatible serving endpoint.
func getSympoziumAgentURL(agentName string) string {
	envKey := "SYMPOZIUM_AGENT_URL_" + strings.ToUpper(strings.ReplaceAll(agentName, "-", "_"))
	if base := os.Getenv(envKey); base != "" {
		return strings.TrimRight(base, "/") + "/"
	}
	if base := os.Getenv("SYMPOZIUM_AGENT_URL"); base != "" && agentName == getDefaultAgent() {
		return strings.TrimRight(base, "/") + "/"
	}
	return fmt.Sprintf("http://%s-web-endpoint-server.%s.svc.cluster.local:8080/", agentName, sympoziumNamespace())
}

// ── Per-agent token cache ─────────────────────────────────────────
// Sympozium creates one Secret per agent named `<agent>-web-proxy-key` with
// a key `api-key`. We cache by agent name to avoid hitting the API per chat.

var (
	tokenMu    sync.RWMutex
	tokenCache = map[string]string{}
)

func getAgentToken(ctx context.Context, agent string) string {
	tokenMu.RLock()
	if v, ok := tokenCache[agent]; ok {
		tokenMu.RUnlock()
		return v
	}
	tokenMu.RUnlock()

	// Fallback to env if cluster lookup fails (e.g. running outside cluster).
	envFallback := os.Getenv("SYMPOZIUM_API_TOKEN")

	if k8sclient.Clientset == nil {
		return envFallback
	}
	secretName := agent + "-web-proxy-key"
	sec, err := k8sclient.Clientset.CoreV1().Secrets(sympoziumNamespace()).Get(ctx, secretName, metav1.GetOptions{})
	if err != nil {
		log.Printf("AI: token lookup for %s failed (%v) — using env fallback", agent, err)
		return envFallback
	}
	token := string(sec.Data["api-key"])
	if token == "" {
		return envFallback
	}
	tokenMu.Lock()
	tokenCache[agent] = token
	tokenMu.Unlock()
	return token
}

// ── System-prompt augmentation ────────────────────────────────────
// We inject a small instruction so the agent knows to emit a structured
// proposal block when the user asks for one of our supported actions.
// The agent's own systemPrompt (defined in its CR) takes priority — this
// is appended as an additional system message so it remains advisory.

const proposalInstruction = `You are the cluster2 management-plane assistant for a Kubernetes platform.
You run inside cluster2 (a Kind cluster) that hosts KubeVirt VMs, CDI DataVolumes,
CAPI Clusters/Machines, MetalLB, and the Sympozium control plane. Users talk to
you to inspect and operate this platform.

Tools available via the k8s-ops sidecar: kubectl, virtctl. Read-only inspection
(get, describe, logs) is always allowed. Never mutate cluster state without
explicit user confirmation. Do not touch namespaces kube-system, capi-system,
capk-system, kubevirt, cdi, metallb-system, istio-system, sympozium-system
except for read-only inspection.

Style: concise. Show the exact command you ran before reporting its result.
Prefer one short paragraph plus a small table over long prose.

Language: always respond in English only. Never emit CJK (Chinese, Japanese,
Korean) characters in any part of the reply, including reasoning, comments,
or examples.

Action proposals: the UI you talk to can execute a small allow-list of
structured actions on the user's behalf. If — and only if — the user asks
to deploy, create, or bring up the target Kubernetes cluster (a k3s cluster
on KubeVirt VMs), end your reply with this exact fenced block:

` + "```json" + `
{"action":"deploy_target_cluster","profile":"lite","reason":"<one short sentence>"}
` + "```" + `

Use profile "lite" by default; use "full" only if the user explicitly says "full".
Do NOT emit this block for any other request — not for status checks, listing
pods or VMs, descriptions, or general chat. Allowed actions today:
deploy_target_cluster. Anything else stays as plain prose.`

// ── Chat handler ──────────────────────────────────────────────────

// HandleAIChat proxies user messages to a Sympozium agent and streams typed
// envelope events back. POST /api/ai/chat
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

	// Build OpenAI messages: prefer multi-turn history if provided, else single message.
	msgs := []oaiMessage{{Role: "system", Content: proposalInstruction}}
	if len(req.Messages) > 0 {
		msgs = append(msgs, req.Messages...)
	} else if req.Message != "" {
		msgs = append(msgs, oaiMessage{Role: "user", Content: req.Message})
	} else {
		writeError(w, http.StatusBadRequest, "message or messages is required")
		return
	}

	agentName := req.Agent
	if agentName == "" {
		agentName = getDefaultAgent()
	}
	agentURL := getSympoziumAgentURL(agentName) + "v1/chat/completions"

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")

	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming not supported")
		return
	}

	body, err := json.Marshal(oaiChatRequest{Model: "default", Stream: true, Messages: msgs})
	if err != nil {
		log.Printf("AI: marshal error: %v", err)
		emitEnvelope(w, flusher, Envelope{Type: "error", Error: "Error preparing request"})
		emitDone(w, flusher)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 120*time.Second)
	defer cancel()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, agentURL, bytes.NewReader(body))
	if err != nil {
		log.Printf("AI: build request error: %v", err)
		emitEnvelope(w, flusher, Envelope{Type: "error", Error: "Error connecting to AI agent"})
		emitDone(w, flusher)
		return
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")
	if token := getAgentToken(ctx, agentName); token != "" {
		httpReq.Header.Set("Authorization", "Bearer "+token)
	}

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		log.Printf("AI: agent %s call error: %v", agentName, err)
		emitEnvelope(w, flusher, Envelope{Type: "error", Error: "Error connecting to AI agent: " + err.Error()})
		emitDone(w, flusher)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// 401: token cache may be stale (rotated) — drop and retry once next call.
		if resp.StatusCode == http.StatusUnauthorized {
			tokenMu.Lock()
			delete(tokenCache, agentName)
			tokenMu.Unlock()
		}
		log.Printf("AI: agent %s returned %d", agentName, resp.StatusCode)
		emitEnvelope(w, flusher, Envelope{Type: "error", Error: fmt.Sprintf("AI agent returned error (status %d)", resp.StatusCode)})
		emitDone(w, flusher)
		return
	}

	// Stream OpenAI SSE → text envelopes; accumulate full text for proposal scan.
	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 256*1024), 256*1024)

	var fullText strings.Builder
	for scanner.Scan() {
		if ctx.Err() != nil {
			break
		}
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "" {
			continue
		}
		if data == "[DONE]" {
			break
		}

		var chunk oaiStreamChunk
		if err := json.Unmarshal([]byte(data), &chunk); err != nil {
			log.Printf("AI: parse chunk error: %v", err)
			continue
		}
		if len(chunk.Choices) == 0 {
			continue
		}
		text := chunk.Choices[0].Delta.Content
		if text != "" {
			fullText.WriteString(text)
			emitEnvelope(w, flusher, Envelope{Type: "text", Text: text})
		}
		if chunk.Choices[0].FinishReason != nil {
			break
		}
	}
	if err := scanner.Err(); err != nil && ctx.Err() == nil {
		log.Printf("AI: stream read error: %v", err)
	}

	// Proposal detection: scan accumulated text for a fenced json block matching
	// our proposal schema, emit one proposal envelope if found.
	if p := extractProposal(fullText.String()); p != nil {
		emitEnvelope(w, flusher, Envelope{Type: "proposal", Proposal: p})
	}

	emitDone(w, flusher)
}

// extractProposal looks for a ```json ... ``` block whose body parses into a
// Proposal with an allowed action. Returns nil if not found / not allowed.
var jsonBlockRE = regexp.MustCompile("(?s)```json\\s*(\\{.*?\\})\\s*```")

func extractProposal(text string) *Proposal {
	matches := jsonBlockRE.FindAllStringSubmatch(text, -1)
	for _, m := range matches {
		if len(m) < 2 {
			continue
		}
		var p Proposal
		if err := json.Unmarshal([]byte(m[1]), &p); err != nil {
			continue
		}
		if !allowedActions[p.Action] {
			continue
		}
		if p.ID == "" {
			p.ID = randomID()
		}
		// Default deploy profile to lite.
		if p.Action == "deploy_target_cluster" && p.Profile == "" {
			p.Profile = "lite"
		}
		return &p
	}
	return nil
}

func randomID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// emitEnvelope writes one Envelope as an SSE data line and flushes.
func emitEnvelope(w http.ResponseWriter, flusher http.Flusher, env Envelope) {
	b, err := json.Marshal(env)
	if err != nil {
		return
	}
	fmt.Fprintf(w, "data: %s\n\n", b)
	flusher.Flush()
}

// emitDone closes the SSE stream with the legacy [DONE] terminator.
func emitDone(w http.ResponseWriter, flusher http.Flusher) {
	fmt.Fprintf(w, "data: [DONE]\n\n")
	flusher.Flush()
}

// ── Action handler ────────────────────────────────────────────────

// ActionRequest is what the UI POSTs to execute an approved proposal.
type ActionRequest struct {
	Action  string `json:"action"`
	Profile string `json:"profile,omitempty"`
}

// HandleAIAction executes an approved agent proposal.
// POST /api/ai/action
// Streams progress as SSE envelopes (tool_step / text / done).
func HandleAIAction(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var req ActionRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if !allowedActions[req.Action] {
		writeError(w, http.StatusForbidden, "action not allowed")
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Connection", "keep-alive")
	w.Header().Set("X-Accel-Buffering", "no")
	flusher, ok := w.(http.Flusher)
	if !ok {
		writeError(w, http.StatusInternalServerError, "streaming not supported")
		return
	}

	switch req.Action {
	case "deploy_target_cluster":
		runDeployActionAsAI(w, flusher, r, req.Profile)
	default:
		emitEnvelope(w, flusher, Envelope{Type: "error", Error: "unhandled action"})
	}
	emitDone(w, flusher)
}

// runDeployActionAsAI kicks the existing deploy flow (or attaches if running)
// and pipes deploy LogEntries out as tool_step envelopes.
func runDeployActionAsAI(w http.ResponseWriter, flusher http.Flusher, r *http.Request, profile string) {
	if _, ok := profileSpecs[profile]; !ok {
		profile = "lite"
	}

	// Start (or attach to) deploy. Don't reset if something else is running —
	// the deploy manager will reject overlap.
	if deploy.getState() != "running" {
		deploy.resetForNewRun()
		setCurrentOp("deploy")
		go runDeployment(profile, "noble")
		emitEnvelope(w, flusher, Envelope{Type: "text", Text: fmt.Sprintf("Starting target cluster deploy (profile=%s)…\n", profile)})
	} else {
		emitEnvelope(w, flusher, Envelope{Type: "text", Text: "A deploy is already in progress — attaching to its log stream.\n"})
	}

	ch := deploy.subscribe()
	defer deploy.unsubscribe(ch)

	for {
		select {
		case <-r.Context().Done():
			return
		case entry := <-ch:
			step := entry
			emitEnvelope(w, flusher, Envelope{Type: "tool_step", Step: &step})
			if entry.Type == "done" {
				return
			}
		case <-time.After(25 * time.Second):
			fmt.Fprintf(w, ": keepalive\n\n")
			flusher.Flush()
		}
	}
}

// ── Agent listing ─────────────────────────────────────────────────

// HandleListAgents enumerates SympoziumInstance CRs with serving enabled.
// GET /api/ai/agents
func HandleListAgents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	type agentInfo struct {
		Name        string `json:"name"`
		Description string `json:"description"`
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	ns := sympoziumNamespace()
	defaultAgent := getDefaultAgent()

	list, err := k8sclient.DynamicClient.Resource(sympoziumInstanceGVR).Namespace(ns).List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("AI: list SympoziumInstances in %s: %v", ns, err)
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]interface{}{
			"agents":  []agentInfo{{Name: defaultAgent, Description: "Default Sympozium agent"}},
			"default": defaultAgent,
		})
		return
	}

	agents := make([]agentInfo, 0, len(list.Items))
	for _, item := range list.Items {
		name := item.GetName()
		description := ""
		if spec, ok := item.Object["spec"].(map[string]interface{}); ok {
			if d, ok := spec["description"].(string); ok {
				description = d
			}
			if serving, ok := spec["serving"].(map[string]interface{}); ok {
				if enabled, ok := serving["enabled"].(bool); ok && !enabled {
					continue
				}
			}
		}
		agents = append(agents, agentInfo{Name: name, Description: description})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"agents":  agents,
		"default": defaultAgent,
	})
}
