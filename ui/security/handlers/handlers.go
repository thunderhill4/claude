package handlers

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"time"

	"kubeui/security/engine"
	"kubeui/security/engine/registry"
	"kubeui/security/llm"
	"kubeui/security/model"
	"kubeui/security/opa"
)

type Handler struct {
	scanner   *engine.Scanner
	evaluator *opa.Evaluator
	llmClient *llm.Client // may be nil
}

func New(scanner *engine.Scanner, evaluator *opa.Evaluator, llmClient *llm.Client) *Handler {
	return &Handler{scanner: scanner, evaluator: evaluator, llmClient: llmClient}
}

// HandleScan handles POST /scan
// Parses the request body as model.ScanRequest, calls scanner.Scan, returns JSON ScanResult.
func (h *Handler) HandleScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req model.ScanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 120*time.Second)
	defer cancel()

	result, err := h.scanner.Scan(ctx, req)
	if err != nil {
		log.Printf("scan error: %v", err)
		http.Error(w, "scan failed: "+err.Error(), http.StatusInternalServerError)
		return
	}
	writeJSON(w, result)
}

// HandleRegistryScan handles POST /scan/registry
// Parses the request body as model.RegistryScanRequest, calls registry.Scan,
// evaluates findings against OPA, and returns model.RegistryScanResult.
func (h *Handler) HandleRegistryScan(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req model.RegistryScanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "bad request: "+err.Error(), http.StatusBadRequest)
		return
	}
	start := time.Now()
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()

	resources, err := registry.Scan(req.RegistryURL, req.Insecure, req.Username, req.Password)
	if err != nil {
		log.Printf("registry scan error: %v", err)
		http.Error(w, "registry scan failed: "+err.Error(), http.StatusInternalServerError)
		return
	}

	var allFindings []model.Finding
	for _, resource := range resources {
		findings, evalErr := h.evaluator.Evaluate(ctx, resource)
		if evalErr != nil {
			log.Printf("opa evaluate error for %s: %v", resource.Name, evalErr)
			continue
		}
		allFindings = append(allFindings, findings...)
	}

	result := model.RegistryScanResult{
		RegistryURL:   req.RegistryURL,
		ImagesScanned: len(resources),
		Findings:      allFindings,
		ScannedAt:     start,
		DurationMs:    time.Since(start).Milliseconds(),
	}
	writeJSON(w, result)
}

// HandleRules handles GET /rules
// Returns model.RulesResponse with all loaded policies.
func (h *Handler) HandleRules(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	rules := h.evaluator.LoadedPolicies()
	writeJSON(w, model.RulesResponse{Rules: rules, Total: len(rules)})
}

// HandleHealthz handles GET /healthz
func (h *Handler) HandleHealthz(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]string{"status": "ok"})
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("json encode error: %v", err)
	}
}
