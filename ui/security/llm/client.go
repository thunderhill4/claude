package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strings"
	"time"

	"kubeui/security/model"
)

// Client is an Ollama-compatible LLM HTTP client.
type Client struct {
	baseURL string
	model   string
}

// NewClient creates a new LLM client targeting the given Ollama-compatible endpoint.
func NewClient(baseURL, model string) *Client {
	return &Client{
		baseURL: strings.TrimRight(baseURL, "/"),
		model:   model,
	}
}

type generateRequest struct {
	Model  string `json:"model"`
	Prompt string `json:"prompt"`
	Stream bool   `json:"stream"`
}

type generateResponse struct {
	Response string `json:"response"`
}

// Enrich calls the LLM to produce remediation advice for the given finding.
// On any error (network, timeout, non-200, JSON decode), it logs and returns "".
func (c *Client) Enrich(ctx context.Context, finding model.Finding) string {
	prompt := fmt.Sprintf(
		"Analyze this security finding and provide remediation advice:\nRule: %s\nTitle: %s\nDescription: %s\nResource: %s\nSeverity: %s\nProvide a brief, actionable remediation.",
		finding.ID,
		finding.Title,
		finding.Description,
		finding.Resource,
		finding.Severity,
	)

	reqBody := generateRequest{
		Model:  c.model,
		Prompt: prompt,
		Stream: false,
	}

	b, err := json.Marshal(reqBody)
	if err != nil {
		log.Printf("llm: marshal request: %v", err)
		return ""
	}

	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/api/generate", bytes.NewReader(b))
	if err != nil {
		log.Printf("llm: create request: %v", err)
		return ""
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("llm: do request: %v", err)
		return ""
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("llm: non-200 status: %d", resp.StatusCode)
		return ""
	}

	var genResp generateResponse
	if err := json.NewDecoder(resp.Body).Decode(&genResp); err != nil {
		log.Printf("llm: decode response: %v", err)
		return ""
	}

	return genResp.Response
}
