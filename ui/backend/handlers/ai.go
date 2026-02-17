package handlers

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

// ChatRequest is the incoming request from the frontend.
type ChatRequest struct {
	Message string `json:"message"`
	Agent   string `json:"agent,omitempty"` // optional: agent service name (default: k8s-agent)
}

// A2A protocol types
type a2aRequest struct {
	JSONRPC string    `json:"jsonrpc"`
	Method  string    `json:"method"`
	Params  a2aParams `json:"params"`
	ID      string    `json:"id"`
}

type a2aParams struct {
	Message a2aMessage `json:"message"`
}

type a2aMessage struct {
	Kind      string    `json:"kind"`
	MessageID string    `json:"messageId"`
	Role      string    `json:"role"`
	Parts     []a2aPart `json:"parts"`
}

type a2aPart struct {
	Kind string `json:"kind"`
	Text string `json:"text,omitempty"`
}

// A2A response parsing types (partial – only what we need)
type a2aResponse struct {
	Result json.RawMessage `json:"result"`
}

type a2aEvent struct {
	Kind     string          `json:"kind"`
	Final    bool            `json:"final"`
	Status   *a2aStatus      `json:"status,omitempty"`
	Parts    []a2aPart       `json:"parts,omitempty"`
	Artifact *a2aArtifact    `json:"artifact,omitempty"`
}

type a2aStatus struct {
	State   string          `json:"state"`
	Message json.RawMessage `json:"message,omitempty"` // can be a string or a message object
}

type a2aArtifact struct {
	Parts []a2aPart `json:"parts,omitempty"`
}

func getAgentURL(agentName string) string {
	ns := os.Getenv("KAGENT_AGENT_NAMESPACE")
	if ns == "" {
		ns = "kagent"
	}
	return fmt.Sprintf("http://%s.%s.svc.cluster.local:8080/", agentName, ns)
}

func getDefaultAgent() string {
	name := os.Getenv("KAGENT_AGENT_NAME")
	if name == "" {
		name = "k8s-agent"
	}
	return name
}

// HandleAIChat proxies user messages to a kagent agent via the A2A protocol
// and streams the response back to the frontend as SSE.
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

	agentName := req.Agent
	if agentName == "" {
		agentName = getDefaultAgent()
	}
	agentURL := getAgentURL(agentName)

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

	// Build A2A request
	msgID := fmt.Sprintf("msg-%d", time.Now().UnixNano())
	reqID := fmt.Sprintf("req-%d", time.Now().UnixNano())

	a2aReq := a2aRequest{
		JSONRPC: "2.0",
		Method:  "message/stream",
		Params: a2aParams{
			Message: a2aMessage{
				Kind:      "message",
				MessageID: msgID,
				Role:      "user",
				Parts:     []a2aPart{{Kind: "text", Text: req.Message}},
			},
		},
		ID: reqID,
	}

	body, err := json.Marshal(a2aReq)
	if err != nil {
		log.Printf("Error marshaling A2A request: %v", err)
		fmt.Fprintf(w, "data: Error preparing request\n\n")
		fmt.Fprintf(w, "data: [DONE]\n\n")
		flusher.Flush()
		return
	}

	// Call kagent agent with timeout
	ctx, cancel := context.WithTimeout(r.Context(), 120*time.Second)
	defer cancel()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodPost, agentURL, bytes.NewReader(body))
	if err != nil {
		log.Printf("Error creating request to kagent agent %s: %v", agentName, err)
		fmt.Fprintf(w, "data: Error connecting to AI agent\n\n")
		fmt.Fprintf(w, "data: [DONE]\n\n")
		flusher.Flush()
		return
	}
	httpReq.Header.Set("Content-Type", "application/json")
	httpReq.Header.Set("Accept", "text/event-stream")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		log.Printf("Error calling kagent agent %s at %s: %v", agentName, agentURL, err)
		fmt.Fprintf(w, "data: Error connecting to AI agent: %s\n\n", jsonEscape(err.Error()))
		fmt.Fprintf(w, "data: [DONE]\n\n")
		flusher.Flush()
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("Kagent agent %s returned status %d", agentName, resp.StatusCode)
		fmt.Fprintf(w, "data: AI agent returned error (status %d)\n\n", resp.StatusCode)
		fmt.Fprintf(w, "data: [DONE]\n\n")
		flusher.Flush()
		return
	}

	// Parse SSE stream from kagent and forward text tokens to frontend
	scanner := bufio.NewScanner(resp.Body)
	// Increase scanner buffer for large SSE lines
	scanner.Buffer(make([]byte, 0, 256*1024), 256*1024)

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

		// Parse the A2A JSON-RPC response
		var a2aResp a2aResponse
		if err := json.Unmarshal([]byte(data), &a2aResp); err != nil {
			log.Printf("Error parsing A2A response: %v", err)
			continue
		}

		var event a2aEvent
		if err := json.Unmarshal(a2aResp.Result, &event); err != nil {
			log.Printf("Error parsing A2A event: %v", err)
			continue
		}

		// Extract text based on event kind
		text := extractText(event)
		if text != "" {
			fmt.Fprintf(w, "data: %s\n\n", jsonEscape(text))
			flusher.Flush()
		}

		if event.Final {
			break
		}
	}

	if err := scanner.Err(); err != nil && ctx.Err() == nil {
		log.Printf("Error reading A2A stream: %v", err)
	}

	fmt.Fprintf(w, "data: [DONE]\n\n")
	flusher.Flush()
}

// a2aFullMessage is a structured message object from the A2A protocol.
type a2aFullMessage struct {
	Role  string    `json:"role"`
	Parts []a2aPart `json:"parts,omitempty"`
}

// extractText pulls text content from an A2A event.
func extractText(event a2aEvent) string {
	switch event.Kind {
	case "status-update":
		if event.Status == nil || len(event.Status.Message) == 0 {
			return ""
		}
		// status.message can be either a plain string or a full message object.
		// Try string first.
		var s string
		if err := json.Unmarshal(event.Status.Message, &s); err == nil {
			return s
		}
		// Try full message object — skip if role is "user" (echo of input).
		var msg a2aFullMessage
		if err := json.Unmarshal(event.Status.Message, &msg); err == nil {
			if msg.Role == "user" {
				return ""
			}
			return partsToText(msg.Parts)
		}
	case "artifact-update":
		// Skip artifact-update — the same text is already sent in status-update events.
		// This avoids duplicate output.
	case "message":
		return partsToText(event.Parts)
	}
	return ""
}

func partsToText(parts []a2aPart) string {
	var sb strings.Builder
	for _, p := range parts {
		if p.Kind == "text" && p.Text != "" {
			sb.WriteString(p.Text)
		}
	}
	return sb.String()
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

// HandleListAgents returns the list of available kagent agents.
// GET /api/ai/agents
func HandleListAgents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	ns := os.Getenv("KAGENT_AGENT_NAMESPACE")
	if ns == "" {
		ns = "kagent"
	}

	controllerURL := fmt.Sprintf("http://kagent-controller.%s.svc.cluster.local:8083/api/agents", ns)

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	httpReq, err := http.NewRequestWithContext(ctx, http.MethodGet, controllerURL, nil)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to create request")
		return
	}

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		log.Printf("Error fetching agents from kagent controller: %v", err)
		writeError(w, http.StatusBadGateway, "failed to fetch agents from kagent")
		return
	}
	defer resp.Body.Close()

	// Parse the controller response to extract agent names
	var controllerResp struct {
		Error bool `json:"error"`
		Data  []struct {
			ID    string `json:"id"`
			Agent struct {
				Metadata struct {
					Name string `json:"name"`
				} `json:"metadata"`
				Spec struct {
					Description string `json:"description"`
				} `json:"spec"`
			} `json:"agent"`
		} `json:"data"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&controllerResp); err != nil {
		log.Printf("Error decoding agents response: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to parse agents response")
		return
	}

	type agentInfo struct {
		Name        string `json:"name"`
		Description string `json:"description"`
	}

	agents := make([]agentInfo, 0, len(controllerResp.Data))
	defaultAgent := getDefaultAgent()
	for _, a := range controllerResp.Data {
		agents = append(agents, agentInfo{
			Name:        a.Agent.Metadata.Name,
			Description: a.Agent.Spec.Description,
		})
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]interface{}{
		"agents":  agents,
		"default": defaultAgent,
	})
}
