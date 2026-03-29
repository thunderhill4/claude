package opa

import (
	"context"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/open-policy-agent/opa/rego"
	"kubeui/security/model"
)

type Evaluator struct {
	policiesDir string
	modules     map[string]string // filepath → rego source
}

func NewEvaluator(dir string) (*Evaluator, error) {
	modules := make(map[string]string)
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !strings.HasSuffix(path, ".rego") {
			return err
		}
		b, readErr := os.ReadFile(path)
		if readErr != nil {
			log.Printf("WARN: skipping policy %s: %v", path, readErr)
			return nil
		}
		modules[path] = string(b)
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("walking policies dir %s: %w", dir, err)
	}
	log.Printf("Loaded %d Rego policies from %s", len(modules), dir)
	return &Evaluator{policiesDir: dir, modules: modules}, nil
}

func (e *Evaluator) Evaluate(ctx context.Context, r model.Resource) ([]model.Finding, error) {
	var allFindings []model.Finding
	for filename, src := range e.modules {
		findings, err := e.runPolicy(ctx, filename, src, r)
		if err != nil {
			log.Printf("WARN: policy %s evaluation error: %v", filename, err)
			continue
		}
		allFindings = append(allFindings, findings...)
	}
	return allFindings, nil
}

func (e *Evaluator) LoadedPolicies() []model.RuleInfo {
	rules := make([]model.RuleInfo, 0, len(e.modules))
	for filename := range e.modules {
		parts := strings.Split(filepath.ToSlash(filename), "/")
		tool := ""
		for i, p := range parts {
			if p == "policies" && i+1 < len(parts) {
				tool = parts[i+1]
				break
			}
		}
		rules = append(rules, model.RuleInfo{
			Policy: filename,
			Tool:   tool,
		})
	}
	return rules
}

func (e *Evaluator) runPolicy(ctx context.Context, filename, src string, r model.Resource) ([]model.Finding, error) {
	pkg := extractPackage(src)
	queryStr := "data.findings"
	if pkg != "" {
		queryStr = "data." + pkg + ".findings"
	}

	query := rego.New(
		rego.Query(queryStr),
		rego.Module(filename, src),
		rego.Input(map[string]any{"resource": r}),
	)

	rs, err := query.Eval(ctx)
	if err != nil {
		return nil, err
	}
	if len(rs) == 0 || len(rs[0].Expressions) == 0 {
		return nil, nil
	}

	set, ok := rs[0].Expressions[0].Value.([]any)
	if !ok {
		return nil, nil
	}

	var findings []model.Finding
	for _, item := range set {
		m, ok := item.(map[string]any)
		if !ok {
			continue
		}
		findings = append(findings, mapToFinding(m))
	}
	return findings, nil
}

func extractPackage(src string) string {
	for _, line := range strings.SplitN(src, "\n", 50) {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "package ") {
			return strings.TrimPrefix(line, "package ")
		}
	}
	return ""
}

func mapToFinding(m map[string]any) model.Finding {
	f := model.Finding{Confidence: 1.0}
	if v, ok := m["id"].(string); ok {
		f.ID = v
	}
	if v, ok := m["severity"].(string); ok {
		f.Severity = v
	}
	if v, ok := m["category"].(string); ok {
		f.Category = v
	}
	if v, ok := m["resource"].(string); ok {
		f.Resource = v
	}
	if v, ok := m["title"].(string); ok {
		f.Title = v
	}
	if v, ok := m["description"].(string); ok {
		f.Description = v
	}
	if v, ok := m["remediation"].(string); ok {
		f.Remediation = v
	}
	if v, ok := m["confidence"].(float64); ok {
		f.Confidence = v
	}
	if loc, ok := m["location"].(map[string]any); ok {
		if line, ok := loc["line"].(float64); ok {
			f.Location.Line = int(line)
		}
		if col, ok := loc["column"].(float64); ok {
			f.Location.Column = int(col)
		}
	}
	return f
}
