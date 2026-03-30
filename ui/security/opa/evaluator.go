package opa

import (
	"context"
	"fmt"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/open-policy-agent/opa/ast"
	"github.com/open-policy-agent/opa/rego"
	"kubeui/security/model"
)

type Evaluator struct {
	policiesDir string
	modules     map[string]string              // filepath → rego source
	prepared    map[string]rego.PreparedEvalQuery // filepath → compiled query
}

func NewEvaluator(dir string) (*Evaluator, error) {
	modules := make(map[string]string)
	err := filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			log.Printf("WARN: skipping %s: %v", path, err)
			return nil // continue walk, don't abort
		}
		if d.IsDir() || !strings.HasSuffix(path, ".rego") {
			return nil
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

	prepared := make(map[string]rego.PreparedEvalQuery)
	for path, src := range modules {
		pkg := extractPackage(src)
		queryStr := "data.findings"
		if pkg != "" {
			queryStr = "data." + pkg + ".findings"
		}
		pq, compileErr := rego.New(
			rego.Query(queryStr),
			rego.Module(path, src),
			rego.SetRegoVersion(ast.RegoV1),
		).PrepareForEval(context.Background())
		if compileErr != nil {
			log.Printf("WARN: failed to compile policy %s: %v", path, compileErr)
			continue
		}
		prepared[path] = pq
	}

	log.Printf("Loaded %d Rego policies from %s", len(modules), dir)
	return &Evaluator{policiesDir: dir, modules: modules, prepared: prepared}, nil
}

func (e *Evaluator) Evaluate(ctx context.Context, r model.Resource) ([]model.Finding, error) {
	var allFindings []model.Finding
	for filename := range e.modules {
		findings, err := e.runPolicy(ctx, filename, r)
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
	for filename, src := range e.modules {
		parts := strings.Split(filepath.ToSlash(filename), "/")
		tool := ""
		for i, p := range parts {
			if p == "policies" && i+1 < len(parts) {
				tool = parts[i+1]
				break
			}
		}
		pkg := extractPackage(src)
		rules = append(rules, model.RuleInfo{
			ID:     pkg,
			Policy: filename,
			Title:  humanizePackage(pkg),
			Tool:   tool,
		})
	}
	return rules
}

func (e *Evaluator) runPolicy(ctx context.Context, path string, r model.Resource) ([]model.Finding, error) {
	pq, ok := e.prepared[path]
	if !ok {
		return nil, nil
	}
	rs, err := pq.Eval(ctx, rego.EvalInput(map[string]any{"resource": r}))
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
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") || strings.HasPrefix(trimmed, "//") {
			continue
		}
		if strings.HasPrefix(trimmed, "package ") {
			return strings.TrimPrefix(trimmed, "package ")
		}
		// If we hit a non-comment, non-empty, non-package line, stop
		break
	}
	return ""
}

func humanizePackage(pkg string) string {
	parts := strings.Split(pkg, ".")
	for i, p := range parts {
		if len(p) > 0 {
			parts[i] = strings.ToUpper(p[:1]) + p[1:]
		}
	}
	return strings.Join(parts, " ")
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
