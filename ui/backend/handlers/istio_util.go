package handlers

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"net/http"
	"strings"
	"time"
)

// sha256Fingerprint renders a PEM certificate's SHA-256 fingerprint in the same
// colon-separated uppercase hex form as
// `openssl x509 -noout -fingerprint -sha256`, so a value shown in the UI can be
// diffed against the CLI output during a demo without transformation.
func sha256Fingerprint(pemBytes []byte) string {
	block, _ := pem.Decode(pemBytes)
	if block == nil {
		return ""
	}
	sum := sha256.Sum256(block.Bytes)
	parts := make([]string, 0, len(sum))
	for _, b := range sum {
		parts = append(parts, fmt.Sprintf("%02X", b))
	}
	return strings.Join(parts, ":")
}

// fetchOllamaModels asks an Ollama-compatible /api/tags endpoint for its model
// list. Called through the agentgateway address rather than directly at Ollama,
// so a success proves the gateway's data path, not just its configuration.
func fetchOllamaModels(ctx context.Context, url string) ([]string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("gateway returned HTTP %d", resp.StatusCode)
	}

	var payload struct {
		Models []struct {
			Name string `json:"name"`
		} `json:"models"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&payload); err != nil {
		return nil, err
	}
	names := make([]string, 0, len(payload.Models))
	for _, m := range payload.Models {
		names = append(names, m.Name)
	}
	return names, nil
}
