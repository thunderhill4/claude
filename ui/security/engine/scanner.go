package engine

import (
	"context"
	"fmt"
	"log"
	"time"

	"kubeui/security/engine/ansible"
	"kubeui/security/engine/kubernetes"
	"kubeui/security/engine/kubevirt"
	"kubeui/security/engine/terraform"
	"kubeui/security/llm"
	"kubeui/security/model"
	"kubeui/security/opa"
)

// Scanner orchestrates parsing, OPA policy evaluation, and optional LLM enrichment.
type Scanner struct {
	evaluator *opa.Evaluator
	llm       *llm.Client // may be nil
}

// NewScanner creates a Scanner with the given OPA evaluator and optional LLM client.
func NewScanner(evaluator *opa.Evaluator, llmClient *llm.Client) *Scanner {
	return &Scanner{
		evaluator: evaluator,
		llm:       llmClient,
	}
}

// Scan parses the file described by req, evaluates OPA policies against each resource,
// and returns a ScanResult. If req.LLMEnrich is true and an LLM client is configured,
// each finding is enriched with LLM-generated advice (logged, not stored in the model).
func (s *Scanner) Scan(ctx context.Context, req model.ScanRequest) (model.ScanResult, error) {
	startTime := time.Now()

	result := model.ScanResult{
		Tool:      req.Tool,
		Filename:  req.Filename,
		ScannedAt: startTime,
	}

	if req.Tool == "registry" {
		// Registry uses its own dedicated scanner; return empty result.
		result.DurationMs = time.Since(startTime).Milliseconds()
		return result, nil
	}

	resources, err := parseContent(req.Tool, req.Filename, []byte(req.Content))
	if err != nil {
		return result, fmt.Errorf("parse %s: %w", req.Tool, err)
	}

	var allFindings []model.Finding
	for _, resource := range resources {
		findings, evalErr := s.evaluator.Evaluate(ctx, resource)
		if evalErr != nil {
			log.Printf("scanner: evaluate resource %s/%s: %v", resource.Type, resource.Name, evalErr)
			continue
		}
		if req.LLMEnrich && s.llm != nil {
			for _, f := range findings {
				advice := s.llm.Enrich(ctx, f)
				if advice != "" {
					log.Printf("scanner: LLM advice for %s: %s", f.ID, advice)
				}
			}
		}
		allFindings = append(allFindings, findings...)
	}

	result.Findings = allFindings
	result.DurationMs = time.Since(startTime).Milliseconds()
	return result, nil
}

// parseContent dispatches to the appropriate parser based on tool name.
func parseContent(tool, filename string, content []byte) ([]model.Resource, error) {
	switch tool {
	case "terraform":
		return terraform.Parse(filename, content)
	case "kubernetes":
		return kubernetes.Parse(content)
	case "kubevirt":
		return kubevirt.Parse(content)
	case "ansible":
		return ansible.Parse(content)
	default:
		return nil, fmt.Errorf("unsupported tool: %q", tool)
	}
}
