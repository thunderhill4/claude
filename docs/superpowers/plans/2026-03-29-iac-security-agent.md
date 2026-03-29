# IaC Security Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a standalone Go microservice that scans Terraform, Kubernetes, Ansible, KubeVirt, and container registry resources for security misconfigurations using OPA/Rego rules and an optional local LLM (Ollama), integrated into the SRE Dashboard as a "Security" sub-view.

**Architecture:** Independent Go service (`ui/security/`, port 8082) deployed as its own Kubernetes Deployment + Service in the `kubeui` namespace. The existing Go backend at `ui/backend/` proxies all `/api/v1/security/*` requests to it. The React frontend adds a "Security" nav item to the SRE sidebar.

**Tech Stack:** Go 1.25, `github.com/open-policy-agent/opa`, `github.com/hashicorp/hcl/v2`, `gopkg.in/yaml.v3`, React 19 + TypeScript + Tailwind v4, `lucide-react`, Kubernetes + Docker Registry v2 API.

**Spec:** `docs/superpowers/specs/2026-03-29-iac-security-agent-design.md`

---

## File Map

### New files — Security Agent (`ui/security/`)
| File | Responsibility |
|------|----------------|
| `ui/security/main.go` | HTTP server, route registration, startup |
| `ui/security/go.mod` | Module `kubeui/security` with deps |
| `ui/security/model/types.go` | `Resource`, `Finding`, `ScanRequest`, `ScanResult`, `RegistryScanRequest`, `RegistryScanResult` |
| `ui/security/opa/evaluator.go` | OPA runtime: load policies from `/policies`, evaluate resource |
| `ui/security/engine/scanner.go` | Orchestrator: route to parser by tool, call OPA, optionally enrich via LLM |
| `ui/security/engine/terraform/parser.go` | Parse HCL files → `[]Resource` |
| `ui/security/engine/kubernetes/parser.go` | Parse K8s YAML manifests → `[]Resource` |
| `ui/security/engine/kubevirt/parser.go` | Parse VM/VMI YAML → `[]Resource` |
| `ui/security/engine/ansible/parser.go` | Parse Ansible playbook YAML → `[]Resource` |
| `ui/security/engine/registry/scanner.go` | Docker v2 API enumeration → `[]Resource` |
| `ui/security/llm/client.go` | Ollama HTTP client for finding enrichment |
| `ui/security/handlers/scan.go` | `POST /scan`, `POST /scan/registry` |
| `ui/security/handlers/rules.go` | `GET /rules` |
| `ui/security/handlers/health.go` | `GET /healthz` |
| `ui/security/opa/policies/terraform/*.rego` | General Terraform rules (iam, network, encryption, secrets) |
| `ui/security/opa/policies/terraform/aws/*.rego` | 13 AWS service rules |
| `ui/security/opa/policies/kubernetes/*.rego` | pod_security, network_policy, secrets, rbac |
| `ui/security/opa/policies/kubevirt/vm_security.rego` | VM/VMI rules |
| `ui/security/opa/policies/registry/registry.rego` | Registry image rules |
| `ui/security/opa/policies/ansible/privilege_escalation.rego` | Ansible rules |

### Modified files — Backend proxy
| File | Change |
|------|--------|
| `ui/backend/handlers/security.go` | New: reverse proxy, strips `/api/v1/security` prefix |
| `ui/backend/main.go` | Add `mux.Handle("/api/v1/security/", ...)` route |

### Modified files — Frontend
| File | Change |
|------|--------|
| `ui/frontend/src/lib/types.ts` | Add `ScanRequest`, `ScanResult`, `RegistryScanRequest`, `RegistryScanResult`, `Finding`, `RulesResponse` |
| `ui/frontend/src/lib/api.ts` | Add `scanIaC`, `scanRegistry`, `getSecurityRules` |
| `ui/frontend/src/components/layout/Sidebar.tsx` | Add Security nav item |
| `ui/frontend/src/pages/SREDashboard.tsx` | Add `case 'security'` |
| `ui/frontend/src/components/sre/SecurityScanner.tsx` | New: entry point for security view |
| `ui/frontend/src/components/security/ScanUpload.tsx` | New: tool selector + file upload/paste |
| `ui/frontend/src/components/security/FindingsList.tsx` | New: findings table grouped by severity |
| `ui/frontend/src/components/security/FindingDetail.tsx` | New: full-page detail view |
| `ui/frontend/src/components/security/SeverityBadge.tsx` | New: colored severity badge |
| `ui/frontend/src/components/security/RegistryScan.tsx` | New: registry URL input + scan trigger |

### Modified files — Infra
| File | Change |
|------|--------|
| `ui/k8s/security-agent.yaml` | New: Deployment, Service, ConfigMap, ServiceAccount |
| `ui/k8s/kubeui.yaml` | Add `SECURITY_AGENT_URL` env var to backend Deployment |
| `Makefile` | Add `security`, `ui-security` targets; extend `ui-build`; update `.PHONY` |
| `run-ui.sh` | Add `SECURITY_AGENT_URL=http://localhost:8082` to backend inline env block |

---

## Task 1: Security Agent — Module scaffold and types

**Files:**
- Create: `ui/security/go.mod`
- Create: `ui/security/model/types.go`
- Create: `ui/security/model/types_test.go`

- [ ] **Step 1: Write the failing test**

```go
// ui/security/model/types_test.go
package model_test

import (
	"encoding/json"
	"testing"
	"time"

	"kubeui/security/model"
)

func TestScanResultJSON(t *testing.T) {
	result := model.ScanResult{
		Tool:      "terraform",
		Filename:  "main.tf",
		Findings:  []model.Finding{},
		ScannedAt: time.Now(),
		DurationMs: 42,
	}
	b, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}
	var out model.ScanResult
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal error: %v", err)
	}
	if out.Tool != "terraform" {
		t.Errorf("want tool=terraform, got %s", out.Tool)
	}
}

func TestFindingDefaults(t *testing.T) {
	f := model.Finding{
		ID:         "TF-NET-001",
		Severity:   "critical",
		Confidence: 1.0,
	}
	if f.Confidence != 1.0 {
		t.Errorf("want confidence=1.0, got %f", f.Confidence)
	}
}
```

- [ ] **Step 2: Run test — expect compile failure (types don't exist yet)**

```bash
cd ui/security && go test ./model/... 2>&1 | head -20
```
Expected: `cannot find package "kubeui/security/model"`

- [ ] **Step 3: Create the Go module**

```
# ui/security/go.mod
module kubeui/security

go 1.25

require (
	github.com/open-policy-agent/opa v0.70.0
	github.com/hashicorp/hcl/v2 v2.22.0
	github.com/zclconf/go-cty v1.15.0
	gopkg.in/yaml.v3 v3.0.1
)
```

Run: `cd ui/security && go mod tidy`

- [ ] **Step 4: Create model/types.go**

```go
// ui/security/model/types.go
package model

import "time"

type Resource struct {
	Tool       string         `json:"tool"`
	Type       string         `json:"type"`
	Name       string         `json:"name"`
	Namespace  string         `json:"namespace,omitempty"`
	Attributes map[string]any `json:"attributes"`
	Location   Location       `json:"location"`
}

type Location struct {
	Line   int `json:"line"`
	Column int `json:"column"`
}

type Finding struct {
	ID          string   `json:"id"`
	Severity    string   `json:"severity"`
	Category    string   `json:"category"`
	Resource    string   `json:"resource"`
	Location    Location `json:"location"`
	Title       string   `json:"title"`
	Description string   `json:"description"`
	Remediation string   `json:"remediation"`
	Confidence  float64  `json:"confidence"`
}

type ScanRequest struct {
	Tool      string `json:"tool"`
	Content   string `json:"content"`
	Filename  string `json:"filename"`
	LLMEnrich bool   `json:"llm_enrich"`
}

type ScanResult struct {
	Tool       string    `json:"tool"`
	Filename   string    `json:"filename"`
	Findings   []Finding `json:"findings"`
	ScannedAt  time.Time `json:"scanned_at"`
	DurationMs int64     `json:"duration_ms"`
}

type RegistryScanRequest struct {
	RegistryURL string `json:"registry_url"`
	Insecure    bool   `json:"insecure"`
	Username    string `json:"username,omitempty"`
	Password    string `json:"password,omitempty"`
	LLMEnrich   bool   `json:"llm_enrich"`
}

type RegistryScanResult struct {
	RegistryURL   string    `json:"registry_url"`
	ImagesScanned int       `json:"images_scanned"`
	Findings      []Finding `json:"findings"`
	ScannedAt     time.Time `json:"scanned_at"`
	DurationMs    int64     `json:"duration_ms"`
}

type RuleInfo struct {
	ID       string `json:"id"`
	Policy   string `json:"policy"`
	Title    string `json:"title"`
	Severity string `json:"severity"`
	Tool     string `json:"tool"`
}

type RulesResponse struct {
	Rules []RuleInfo `json:"rules"`
	Total int        `json:"total"`
}
```

- [ ] **Step 5: Run tests — expect PASS**

```bash
cd ui/security && go test ./model/... -v
```
Expected: `PASS`

- [ ] **Step 6: Commit**

```bash
git add ui/security/go.mod ui/security/go.sum ui/security/model/
git commit -m "feat(security): scaffold module and domain types"
```

---

## Task 2: OPA evaluator

**Files:**
- Create: `ui/security/opa/evaluator.go`
- Create: `ui/security/opa/evaluator_test.go`
- Create: `ui/security/opa/policies/terraform/network.rego` (seed policy for testing)

- [ ] **Step 1: Write the seed Rego policy**

```rego
# ui/security/opa/policies/terraform/network.rego
package terraform.network

import future.keywords.if
import future.keywords.contains

findings contains finding if {
    resource := input.resource
    resource.type == "aws_security_group"
    ingress := resource.attributes.ingress[_]
    ingress.cidr_blocks[_] == "0.0.0.0/0"
    ingress.from_port == 0
    ingress.to_port == 0
    finding := {
        "id": "TF-NET-001",
        "severity": "critical",
        "category": "network",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "Unrestricted ingress on all ports",
        "description": "Security group allows unrestricted inbound traffic (0.0.0.0/0) on all ports.",
        "remediation": "Restrict ingress rules to specific CIDR ranges and required ports only.",
        "confidence": 1.0,
    }
}
```

- [ ] **Step 2: Write the failing test**

```go
// ui/security/opa/evaluator_test.go
package opa_test

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"kubeui/security/model"
	secopa "kubeui/security/opa"
)

func TestEvaluatorFindsUnrestrictedIngress(t *testing.T) {
	// point evaluator at the real policies dir
	dir := "policies"
	eval, err := secopa.NewEvaluator(dir)
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}

	r := model.Resource{
		Tool: "terraform",
		Type: "aws_security_group",
		Name: "web_sg",
		Attributes: map[string]any{
			"ingress": []any{
				map[string]any{
					"cidr_blocks": []any{"0.0.0.0/0"},
					"from_port":   float64(0),
					"to_port":     float64(0),
				},
			},
		},
		Location: model.Location{Line: 1},
	}

	findings, err := eval.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(findings) == 0 {
		t.Fatal("expected at least one finding, got none")
	}
	if findings[0].ID != "TF-NET-001" {
		t.Errorf("expected TF-NET-001, got %s", findings[0].ID)
	}
}

func TestEvaluatorNoFindingsForSafeResource(t *testing.T) {
	dir := "policies"
	eval, err := secopa.NewEvaluator(dir)
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}

	r := model.Resource{
		Tool: "terraform",
		Type: "aws_s3_bucket",
		Name: "safe_bucket",
		Attributes: map[string]any{},
	}

	findings, err := eval.Evaluate(context.Background(), r)
	if err != nil {
		t.Fatalf("Evaluate: %v", err)
	}
	if len(findings) != 0 {
		t.Errorf("expected no findings for safe resource, got %d", len(findings))
	}
}
```

- [ ] **Step 3: Run test — expect compile failure**

```bash
cd ui/security && go test ./opa/... 2>&1 | head -20
```
Expected: `cannot find package "kubeui/security/opa"`

- [ ] **Step 4: Implement opa/evaluator.go**

```go
// ui/security/opa/evaluator.go
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

// Evaluator loads Rego policies and evaluates resources against them.
type Evaluator struct {
	policiesDir string
	modules     map[string]string // filename → rego source
}

// NewEvaluator loads all *.rego files from dir recursively.
// Policies that fail to parse are logged and skipped.
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

// Evaluate runs all loaded policies against r and returns all findings.
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

// LoadedPolicies returns metadata for all successfully loaded policies.
func (e *Evaluator) LoadedPolicies() []model.RuleInfo {
	rules := make([]model.RuleInfo, 0, len(e.modules))
	for filename := range e.modules {
		// derive tool from path: policies/terraform/network.rego → terraform
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
	// Derive query path from the package declaration.
	// "package terraform.network" → query "data.terraform.network.findings"
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

	// OPA returns a set as []interface{}; cast accordingly.
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
		f := mapToFinding(m)
		findings = append(findings, f)
	}
	return findings, nil
}

// extractPackage parses the first "package X" line from Rego source.
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
```

- [ ] **Step 5: Run tests — expect PASS**

```bash
cd ui/security && go test ./opa/... -v
```
Expected: both tests PASS

- [ ] **Step 6: Commit**

```bash
git add ui/security/opa/
git commit -m "feat(security): add OPA evaluator and seed network policy"
```

---

## Task 3: Terraform HCL parser

**Files:**
- Create: `ui/security/engine/terraform/parser.go`
- Create: `ui/security/engine/terraform/parser_test.go`

- [ ] **Step 1: Write the failing test**

```go
// ui/security/engine/terraform/parser_test.go
package terraform_test

import (
	"testing"

	tfparser "kubeui/security/engine/terraform"
)

const tfContent = `
resource "aws_security_group" "web_sg" {
  name = "web-sg"
  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
  }
}
`

func TestParseTerraformResources(t *testing.T) {
	resources, err := tfparser.Parse("main.tf", []byte(tfContent))
	if err != nil {
		t.Fatalf("Parse error: %v", err)
	}
	if len(resources) == 0 {
		t.Fatal("expected at least one resource")
	}
	r := resources[0]
	if r.Type != "aws_security_group" {
		t.Errorf("want type=aws_security_group, got %s", r.Type)
	}
	if r.Name != "web_sg" {
		t.Errorf("want name=web_sg, got %s", r.Name)
	}
	if r.Tool != "terraform" {
		t.Errorf("want tool=terraform, got %s", r.Tool)
	}
}
```

- [ ] **Step 2: Run — expect compile failure**

```bash
cd ui/security && go test ./engine/terraform/... 2>&1 | head -10
```

- [ ] **Step 3: Implement terraform/parser.go**

```go
// ui/security/engine/terraform/parser.go
package terraform

import (
	"fmt"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
	"kubeui/security/model"
)

// Parse parses HCL terraform content and returns a slice of Resources.
func Parse(filename string, content []byte) ([]model.Resource, error) {
	file, diags := hclsyntax.ParseConfig(content, filename, hcl.Pos{Line: 1, Column: 1})
	if diags.HasErrors() {
		return nil, fmt.Errorf("HCL parse error: %s", diags.Error())
	}

	body, ok := file.Body.(*hclsyntax.Body)
	if !ok {
		return nil, fmt.Errorf("unexpected body type")
	}

	var resources []model.Resource
	for _, block := range body.Blocks {
		if block.Type != "resource" || len(block.Labels) < 2 {
			continue
		}
		r := model.Resource{
			Tool:      "terraform",
			Type:      block.Labels[0],
			Name:      block.Labels[1],
			Attributes: extractAttributes(block.Body),
			Location: model.Location{
				Line:   block.OpenBraceRange.Start.Line,
				Column: block.OpenBraceRange.Start.Column,
			},
		}
		resources = append(resources, r)
	}
	return resources, nil
}

// extractAttributes converts an hclsyntax.Body into a map[string]any.
// Nested blocks are represented as []any of maps.
func extractAttributes(body *hclsyntax.Body) map[string]any {
	attrs := make(map[string]any)

	// Literal attributes
	for name, attr := range body.Attributes {
		val, diags := attr.Expr.Value(nil)
		if diags.HasErrors() {
			attrs[name] = attr.Expr.StartRange().String()
			continue
		}
		attrs[name] = ctyToGo(val)
	}

	// Nested blocks (e.g. ingress {})
	blockGroups := make(map[string][]any)
	for _, block := range body.Blocks {
		nested := extractAttributes(block.Body)
		blockGroups[block.Type] = append(blockGroups[block.Type], nested)
	}
	for k, v := range blockGroups {
		if len(v) == 1 {
			attrs[k] = v[0]
		} else {
			attrs[k] = v
		}
	}
	return attrs
}

func ctyToGo(val cty.Value) any {
	if val.IsNull() || !val.IsKnown() {
		return nil
	}
	t := val.Type()
	switch {
	case t == cty.String:
		return val.AsString()
	case t == cty.Number:
		f, _ := val.AsBigFloat().Float64()
		return f
	case t == cty.Bool:
		return val.True()
	case t.IsListType() || t.IsTupleType() || t.IsSetType():
		var items []any
		for it := val.ElementIterator(); it.Next(); {
			_, v := it.Element()
			items = append(items, ctyToGo(v))
		}
		return items
	case t.IsObjectType() || t.IsMapType():
		m := make(map[string]any)
		for it := val.ElementIterator(); it.Next(); {
			k, v := it.Element()
			m[k.AsString()] = ctyToGo(v)
		}
		return m
	default:
		return fmt.Sprintf("%v", val)
	}
}
```

> Note: `ctyToGo` is intentionally minimal here. The OPA policies work with string comparisons for CIDR blocks; a more complete implementation should use `github.com/zclconf/go-cty/cty/json` to properly serialize complex types. This is sufficient for the initial policy set.

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd ui/security && go test ./engine/terraform/... -v
```

- [ ] **Step 5: Commit**

```bash
git add ui/security/engine/terraform/
git commit -m "feat(security): add Terraform HCL parser"
```

---

## Task 4: Kubernetes YAML parser

**Files:**
- Create: `ui/security/engine/kubernetes/parser.go`
- Create: `ui/security/engine/kubernetes/parser_test.go`

- [ ] **Step 1: Write the failing test**

```go
// ui/security/engine/kubernetes/parser_test.go
package kubernetes_test

import (
	"testing"

	k8sparser "kubeui/security/engine/kubernetes"
)

const podYAML = `
apiVersion: v1
kind: Pod
metadata:
  name: dangerous-pod
  namespace: default
spec:
  containers:
  - name: app
    image: nginx:latest
    securityContext:
      privileged: true
`

const secretYAML = `
apiVersion: v1
kind: Secret
metadata:
  name: db-creds
  namespace: default
stringData:
  password: "supersecret123"
`

func TestParsePod(t *testing.T) {
	resources, err := k8sparser.Parse([]byte(podYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(resources) == 0 {
		t.Fatal("expected resources")
	}
	r := resources[0]
	if r.Type != "Pod" {
		t.Errorf("want Pod, got %s", r.Type)
	}
	if r.Name != "dangerous-pod" {
		t.Errorf("want dangerous-pod, got %s", r.Name)
	}
	if r.Tool != "kubernetes" {
		t.Errorf("want kubernetes, got %s", r.Tool)
	}
}

func TestParseSecret(t *testing.T) {
	resources, err := k8sparser.Parse([]byte(secretYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(resources) == 0 || resources[0].Type != "Secret" {
		t.Fatal("expected Secret resource")
	}
}
```

- [ ] **Step 2: Run — expect compile failure**

```bash
cd ui/security && go test ./engine/kubernetes/... 2>&1 | head -10
```

- [ ] **Step 3: Implement kubernetes/parser.go**

```go
// ui/security/engine/kubernetes/parser.go
package kubernetes

import (
	"bytes"
	"fmt"

	"gopkg.in/yaml.v3"
	"kubeui/security/model"
)

// Parse parses one or more YAML documents (separated by ---) into Resources.
func Parse(content []byte) ([]model.Resource, error) {
	var resources []model.Resource
	dec := yaml.NewDecoder(bytes.NewReader(content))

	for {
		var raw map[string]any
		if err := dec.Decode(&raw); err != nil {
			break // io.EOF or parse error — stop
		}
		if raw == nil {
			continue
		}
		r, err := mapToResource(raw)
		if err != nil {
			continue // skip unparseable docs
		}
		resources = append(resources, r)
	}
	return resources, nil
}

func mapToResource(raw map[string]any) (model.Resource, error) {
	kind, _ := raw["kind"].(string)
	if kind == "" {
		return model.Resource{}, fmt.Errorf("missing kind")
	}
	meta, _ := raw["metadata"].(map[string]any)
	name, _ := meta["name"].(string)
	ns, _ := meta["namespace"].(string)

	return model.Resource{
		Tool:       "kubernetes",
		Type:       kind,
		Name:       name,
		Namespace:  ns,
		Attributes: raw,
	}, nil
}
```

- [ ] **Step 4: Run tests — expect PASS**

```bash
cd ui/security && go test ./engine/kubernetes/... -v
```

- [ ] **Step 5: Commit**

```bash
git add ui/security/engine/kubernetes/
git commit -m "feat(security): add Kubernetes YAML parser"
```

---

## Task 5: KubeVirt, Ansible, and Registry parsers

**Files:**
- Create: `ui/security/engine/kubevirt/parser.go`
- Create: `ui/security/engine/ansible/parser.go`
- Create: `ui/security/engine/registry/scanner.go`
- Create: `ui/security/engine/registry/scanner_test.go`

- [ ] **Step 1: Implement kubevirt/parser.go**

KubeVirt resources are YAML like Kubernetes. Reuse the kubernetes parser but tag tool as `kubevirt`:

```go
// ui/security/engine/kubevirt/parser.go
package kubevirt

import (
	"bytes"

	"gopkg.in/yaml.v3"
	"kubeui/security/model"
)

// Parse parses VirtualMachine/VMITemplate YAML into Resources.
func Parse(content []byte) ([]model.Resource, error) {
	var resources []model.Resource
	dec := yaml.NewDecoder(bytes.NewReader(content))
	for {
		var raw map[string]any
		if err := dec.Decode(&raw); err != nil {
			break // io.EOF or parse error — stop
		}
		if raw == nil {
			continue
		}
		kind, _ := raw["kind"].(string)
		if kind == "" {
			continue
		}
		meta, _ := raw["metadata"].(map[string]any)
		name, _ := meta["name"].(string)
		ns, _ := meta["namespace"].(string)
		resources = append(resources, model.Resource{
			Tool: "kubevirt", Type: kind, Name: name, Namespace: ns, Attributes: raw,
		})
	}
	return resources, nil
}
```

- [ ] **Step 2: Implement ansible/parser.go**

```go
// ui/security/engine/ansible/parser.go
package ansible

import (
	"gopkg.in/yaml.v3"
	"kubeui/security/model"
)

// Parse parses an Ansible playbook YAML into Resources (one per task).
func Parse(content []byte) ([]model.Resource, error) {
	var plays []map[string]any
	if err := yaml.Unmarshal(content, &plays); err != nil {
		return nil, err
	}

	var resources []model.Resource
	for _, play := range plays {
		tasks, _ := play["tasks"].([]any)
		for _, t := range tasks {
			task, ok := t.(map[string]any)
			if !ok {
				continue
			}
			name, _ := task["name"].(string)
			resources = append(resources, model.Resource{
				Tool:       "ansible",
				Type:       "task",
				Name:       name,
				Attributes: task,
			})
		}
	}
	return resources, nil
}
```

- [ ] **Step 3: Write registry scanner test**

```go
// ui/security/engine/registry/scanner_test.go
package registry_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	regscanner "kubeui/security/engine/registry"
)

func TestScanRegistryReturnsResources(t *testing.T) {
	// Minimal Docker v2 API mock
	mux := http.NewServeMux()
	mux.HandleFunc("/v2/_catalog", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"repositories":["myimage"]}`))
	})
	mux.HandleFunc("/v2/myimage/tags/list", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"name":"myimage","tags":["latest"]}`))
	})
	mux.HandleFunc("/v2/myimage/manifests/latest", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.docker.distribution.manifest.v2+json")
		w.Write([]byte(`{"schemaVersion":2,"config":{"digest":"sha256:abc"}}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	resources, err := regscanner.Scan(srv.URL, true, "", "")
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(resources) == 0 {
		t.Fatal("expected at least one image resource")
	}
	if resources[0].Tool != "registry" {
		t.Errorf("want tool=registry, got %s", resources[0].Tool)
	}
}
```

- [ ] **Step 4: Run — expect compile failure**

```bash
cd ui/security && go test ./engine/registry/... 2>&1 | head -10
```

- [ ] **Step 5: Implement registry/scanner.go**

```go
// ui/security/engine/registry/scanner.go
package registry

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"kubeui/security/model"
)

// Scan enumerates images in a Docker v2 registry and returns Resources.
func Scan(registryURL string, insecure bool, username, password string) ([]model.Resource, error) {
	base := strings.TrimRight(registryURL, "/")
	if !strings.HasPrefix(base, "http") {
		scheme := "https"
		if insecure {
			scheme = "http"
		}
		base = scheme + "://" + base
	}

	client := &http.Client{Timeout: 30 * time.Second}

	// List repositories
	repos, err := getJSON[struct {
		Repositories []string `json:"repositories"`
	}](client, base+"/v2/_catalog", username, password)
	if err != nil {
		return nil, fmt.Errorf("listing catalog: %w", err)
	}

	var resources []model.Resource
	for _, repo := range repos.Repositories {
		tags, err := getJSON[struct {
			Tags []string `json:"tags"`
		}](client, fmt.Sprintf("%s/v2/%s/tags/list", base, repo), username, password)
		if err != nil {
			continue
		}

		for _, tag := range tags.Tags {
			attrs := map[string]any{
				"repository": repo,
				"tag":        tag,
				"registry":   base,
				// mutable tag check: "latest" without digest is flagged by policy
				"is_mutable_tag": tag == "latest",
			}
			resources = append(resources, model.Resource{
				Tool:       "registry",
				Type:       "image",
				Name:       fmt.Sprintf("%s:%s", repo, tag),
				Attributes: attrs,
			})
		}
	}
	return resources, nil
}

func getJSON[T any](client *http.Client, url, user, pass string) (T, error) {
	var zero T
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return zero, err
	}
	if user != "" {
		req.SetBasicAuth(user, pass)
	}
	resp, err := client.Do(req)
	if err != nil {
		return zero, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return zero, err
	}
	var result T
	return result, json.Unmarshal(b, &result)
}
```

- [ ] **Step 6: Run tests — expect PASS**

```bash
cd ui/security && go test ./engine/... -v
```

- [ ] **Step 7: Commit**

```bash
git add ui/security/engine/
git commit -m "feat(security): add KubeVirt, Ansible, and Registry parsers"
```

---

## Task 6: LLM client and scanner orchestrator

**Files:**
- Create: `ui/security/llm/client.go`
- Create: `ui/security/engine/scanner.go`
- Create: `ui/security/engine/scanner_test.go`

- [ ] **Step 1: Implement llm/client.go**

```go
// ui/security/llm/client.go
package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"time"

	"kubeui/security/model"
)

type Client struct {
	baseURL string
	model   string
	http    *http.Client
}

func New() *Client {
	url := os.Getenv("OLLAMA_URL")
	if url == "" {
		url = "http://localhost:11434"
	}
	m := os.Getenv("OLLAMA_MODEL")
	if m == "" {
		m = "llama3"
	}
	return &Client{
		baseURL: url,
		model:   m,
		http:    &http.Client{Timeout: 10 * time.Second},
	}
}

type ollamaRequest struct {
	Model  string `json:"model"`
	Prompt string `json:"prompt"`
	Stream bool   `json:"stream"`
}

type ollamaResponse struct {
	Response string `json:"response"`
}

// Enrich uses the local LLM to improve a finding's remediation text and adjust confidence.
// If the LLM is unavailable, the finding is returned unchanged with confidence=1.0.
func (c *Client) Enrich(ctx context.Context, f model.Finding, resource model.Resource) model.Finding {
	prompt := fmt.Sprintf(
		"Security finding: %s\nResource type: %s\nResource name: %s\nDescription: %s\n\nProvide a concise, specific remediation recommendation (2-3 sentences) and a confidence score (0.0-1.0) that this is a true positive given the context. Format: REMEDIATION: <text> CONFIDENCE: <score>",
		f.Title, resource.Type, resource.Name, f.Description,
	)

	body, _ := json.Marshal(ollamaRequest{Model: c.model, Prompt: prompt, Stream: false})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.baseURL+"/api/generate", bytes.NewReader(body))
	if err != nil {
		return f
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := c.http.Do(req)
	if err != nil {
		log.Printf("LLM unavailable, skipping enrichment: %v", err)
		return f
	}
	defer resp.Body.Close()

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return f
	}

	var ollResp ollamaResponse
	if err := json.Unmarshal(b, &ollResp); err != nil {
		return f
	}

	// Parse REMEDIATION: ... CONFIDENCE: ... from response
	parseEnrichment(ollResp.Response, &f)
	return f
}

func parseEnrichment(text string, f *model.Finding) {
	// Simple string parsing — extract REMEDIATION and CONFIDENCE tokens
	var confidence float64
	var remediation string
	fmt.Sscanf(extractAfter(text, "CONFIDENCE:"), "%f", &confidence)
	remediation = extractAfter(text, "REMEDIATION:")
	if idx := indexOf(remediation, "CONFIDENCE:"); idx > 0 {
		remediation = remediation[:idx]
	}
	remediation = trim(remediation)
	if remediation != "" {
		f.Remediation = remediation
	}
	if confidence > 0 && confidence <= 1.0 {
		f.Confidence = confidence
	}
}

func extractAfter(s, prefix string) string {
	idx := indexOf(s, prefix)
	if idx < 0 {
		return ""
	}
	return s[idx+len(prefix):]
}

func indexOf(s, sub string) int {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}

func trim(s string) string {
	return bytes.NewBuffer(bytes.TrimSpace([]byte(s))).String()
}
```

- [ ] **Step 2: Write scanner orchestrator test**

```go
// ui/security/engine/scanner_test.go
package engine_test

import (
	"context"
	"testing"

	"kubeui/security/engine"
	"kubeui/security/model"
	"kubeui/security/opa"
)

func TestScanTerraformContent(t *testing.T) {
	eval, err := opa.NewEvaluator("../opa/policies")
	if err != nil {
		t.Fatalf("evaluator: %v", err)
	}
	scanner := engine.NewScanner(eval, nil) // nil = no LLM

	req := model.ScanRequest{
		Tool:     "terraform",
		Filename: "main.tf",
		Content: `
resource "aws_security_group" "web" {
  ingress {
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 0
    to_port     = 0
  }
}`,
	}

	result, err := scanner.Scan(context.Background(), req)
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if result.Tool != "terraform" {
		t.Errorf("want terraform, got %s", result.Tool)
	}
	// End-to-end: must detect TF-NET-001 (unrestricted ingress)
	found := false
	for _, f := range result.Findings {
		if f.ID == "TF-NET-001" {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("expected TF-NET-001 finding in results, got %d findings: %v", len(result.Findings), result.Findings)
	}
}
```

- [ ] **Step 3: Run — expect compile failure**

```bash
cd ui/security && go test ./engine/... 2>&1 | head -10
```

- [ ] **Step 4: Implement engine/scanner.go**

```go
// ui/security/engine/scanner.go
package engine

import (
	"context"
	"fmt"
	"time"

	"kubeui/security/engine/ansible"
	"kubeui/security/engine/kubernetes"
	"kubeui/security/engine/kubevirt"
	regscanner "kubeui/security/engine/registry"
	tfparser "kubeui/security/engine/terraform"
	"kubeui/security/llm"
	"kubeui/security/model"
	"kubeui/security/opa"
)

// Scanner orchestrates parsing + OPA evaluation + optional LLM enrichment.
type Scanner struct {
	eval      *opa.Evaluator
	llmClient *llm.Client
}

// NewScanner creates a Scanner. llmClient may be nil to disable enrichment.
func NewScanner(eval *opa.Evaluator, llmClient *llm.Client) *Scanner {
	return &Scanner{eval: eval, llmClient: llmClient}
}

// Scan parses IaC content and evaluates all resources against OPA policies.
func (s *Scanner) Scan(ctx context.Context, req model.ScanRequest) (model.ScanResult, error) {
	start := time.Now()

	resources, err := s.parse(req)
	if err != nil {
		return model.ScanResult{}, fmt.Errorf("parsing %s: %w", req.Tool, err)
	}

	var allFindings []model.Finding
	// Total LLM budget: 60 seconds
	llmCtx, llmCancel := context.WithTimeout(ctx, 60*time.Second)
	defer llmCancel()

	for _, r := range resources {
		findings, err := s.eval.Evaluate(ctx, r)
		if err != nil {
			continue
		}
		if req.LLMEnrich && s.llmClient != nil {
			for i := range findings {
				perFindingCtx, cancel := context.WithTimeout(llmCtx, 10*time.Second)
				findings[i] = s.llmClient.Enrich(perFindingCtx, findings[i], r)
				cancel()
			}
		}
		allFindings = append(allFindings, findings...)
	}

	if allFindings == nil {
		allFindings = []model.Finding{}
	}

	return model.ScanResult{
		Tool:       req.Tool,
		Filename:   req.Filename,
		Findings:   allFindings,
		ScannedAt:  time.Now(),
		DurationMs: time.Since(start).Milliseconds(),
	}, nil
}

// ScanRegistry enumerates and evaluates a container registry.
func (s *Scanner) ScanRegistry(ctx context.Context, req model.RegistryScanRequest) (model.RegistryScanResult, error) {
	start := time.Now()

	resources, err := regscanner.Scan(req.RegistryURL, req.Insecure, req.Username, req.Password)
	if err != nil {
		return model.RegistryScanResult{}, err
	}

	var allFindings []model.Finding
	for _, r := range resources {
		findings, err := s.eval.Evaluate(ctx, r)
		if err != nil {
			continue
		}
		allFindings = append(allFindings, findings...)
	}

	if allFindings == nil {
		allFindings = []model.Finding{}
	}

	return model.RegistryScanResult{
		RegistryURL:   req.RegistryURL,
		ImagesScanned: len(resources),
		Findings:      allFindings,
		ScannedAt:     time.Now(),
		DurationMs:    time.Since(start).Milliseconds(),
	}, nil
}

func (s *Scanner) parse(req model.ScanRequest) ([]model.Resource, error) {
	content := []byte(req.Content)
	switch req.Tool {
	case "terraform":
		return tfparser.Parse(req.Filename, content)
	case "kubernetes":
		return kubernetes.Parse(content)
	case "kubevirt":
		return kubevirt.Parse(content)
	case "ansible":
		return ansible.Parse(content)
	default:
		return nil, fmt.Errorf("unsupported tool: %s", req.Tool)
	}
}
```

- [ ] **Step 5: Run tests — expect PASS**

```bash
cd ui/security && go test ./... -v 2>&1 | tail -20
```

- [ ] **Step 6: Commit**

```bash
git add ui/security/llm/ ui/security/engine/scanner.go ui/security/engine/scanner_test.go
git commit -m "feat(security): add LLM client and scanner orchestrator"
```

---

## Task 7: HTTP handlers and main.go

**Files:**
- Create: `ui/security/handlers/health.go`
- Create: `ui/security/handlers/rules.go`
- Create: `ui/security/handlers/scan.go`
- Create: `ui/security/main.go`

- [ ] **Step 1: Create handlers/health.go**

```go
// ui/security/handlers/health.go
package handlers

import "net/http"

func HandleHealth(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}
```

- [ ] **Step 2: Create handlers/rules.go**

```go
// ui/security/handlers/rules.go
package handlers

import (
	"encoding/json"
	"net/http"

	"kubeui/security/model"
	"kubeui/security/opa"
)

type RulesHandler struct {
	Eval *opa.Evaluator
}

func (h *RulesHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	rules := h.Eval.LoadedPolicies()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(model.RulesResponse{Rules: rules, Total: len(rules)})
}
```

- [ ] **Step 3: Create handlers/scan.go**

```go
// ui/security/handlers/scan.go
package handlers

import (
	"encoding/json"
	"net/http"

	"kubeui/security/engine"
	"kubeui/security/model"
)

type ScanHandler struct {
	Scanner *engine.Scanner
}

func (h *ScanHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req model.ScanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.Tool == "" {
		writeError(w, http.StatusBadRequest, "tool is required")
		return
	}
	if req.Content == "" {
		writeError(w, http.StatusBadRequest, "content is required")
		return
	}

	result, err := h.Scanner.Scan(r.Context(), req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

type RegistryScanHandler struct {
	Scanner *engine.Scanner
}

func (h *RegistryScanHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	var req model.RegistryScanRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if req.RegistryURL == "" {
		writeError(w, http.StatusBadRequest, "registry_url is required")
		return
	}

	result, err := h.Scanner.ScanRegistry(r.Context(), req)
	if err != nil {
		writeError(w, http.StatusBadGateway, err.Error())
		return
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(result)
}

func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
```

- [ ] **Step 4: Create main.go**

```go
// ui/security/main.go
package main

import (
	"log"
	"net/http"
	"os"

	"kubeui/security/engine"
	"kubeui/security/handlers"
	"kubeui/security/llm"
	"kubeui/security/opa"
)

func main() {
	policiesDir := os.Getenv("OPA_POLICIES_DIR")
	if policiesDir == "" {
		policiesDir = "opa/policies"
	}

	eval, err := opa.NewEvaluator(policiesDir)
	if err != nil {
		log.Fatalf("Failed to load OPA policies: %v", err)
	}

	llmClient := llm.New()
	scanner := engine.NewScanner(eval, llmClient)

	mux := http.NewServeMux()
	mux.Handle("/scan", &handlers.ScanHandler{Scanner: scanner})
	mux.Handle("/scan/registry", &handlers.RegistryScanHandler{Scanner: scanner})
	mux.Handle("/rules", &handlers.RulesHandler{Eval: eval})
	mux.HandleFunc("/healthz", handlers.HandleHealth)

	port := ":8082"
	log.Printf("Security agent starting on %s (policies: %s)", port, policiesDir)
	if err := http.ListenAndServe(port, mux); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
```

- [ ] **Step 5: Verify the service compiles and starts**

```bash
cd ui/security && go build . && echo "BUILD OK"
```
Expected: `BUILD OK`

- [ ] **Step 6: Commit**

```bash
git add ui/security/handlers/ ui/security/main.go
git commit -m "feat(security): add HTTP handlers and main server"
```

---

## Task 8: Remaining OPA policies

**Files:** All `*.rego` files under `ui/security/opa/policies/`

- [ ] **Step 1: Create terraform/iam.rego**

```rego
# ui/security/opa/policies/terraform/iam.rego
package terraform.iam

import future.keywords.if
import future.keywords.contains

findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    contains(lower(resource.type), "iam")
    policy_doc := resource.attributes.policy
    contains(policy_doc, "\"*\"")
    finding := {
        "id": "TF-IAM-001",
        "severity": "high",
        "category": "iam",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "IAM policy uses wildcard action or resource",
        "description": "The IAM policy contains a wildcard (*) for actions or resources, granting overly broad permissions.",
        "remediation": "Replace wildcards with specific actions and resource ARNs following least-privilege.",
        "confidence": 1.0,
    }
}
```

- [ ] **Step 2: Create terraform/encryption.rego**

```rego
# ui/security/opa/policies/terraform/encryption.rego
package terraform.encryption

import future.keywords.if
import future.keywords.contains

findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_db_instance"
    not resource.attributes.storage_encrypted
    finding := {
        "id": "TF-ENC-001",
        "severity": "high",
        "category": "encryption",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "RDS instance storage is not encrypted",
        "description": "The RDS instance does not have storage_encrypted set to true.",
        "remediation": "Set storage_encrypted = true on the aws_db_instance resource.",
        "confidence": 1.0,
    }
}

findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_s3_bucket"
    not resource.attributes.server_side_encryption_configuration
    finding := {
        "id": "TF-ENC-002",
        "severity": "medium",
        "category": "encryption",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "S3 bucket lacks server-side encryption configuration",
        "description": "No server_side_encryption_configuration block found on the S3 bucket.",
        "remediation": "Add server_side_encryption_configuration with AES256 or aws:kms.",
        "confidence": 1.0,
    }
}
```

- [ ] **Step 3: Create terraform/secrets.rego**

```rego
# ui/security/opa/policies/terraform/secrets.rego
package terraform.secrets

import future.keywords.if
import future.keywords.contains

findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    attr := resource.attributes
    # Detect common password attribute names with non-variable values
    password_keys := {"password", "secret", "api_key", "token", "private_key"}
    key := password_keys[_]
    val := attr[key]
    is_string(val)
    not startswith(val, "var.")
    not startswith(val, "${")
    count(val) > 4
    finding := {
        "id": "TF-SEC-001",
        "severity": "critical",
        "category": "secrets",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": sprintf("Hardcoded secret in attribute '%v'", [key]),
        "description": sprintf("The attribute '%v' appears to contain a hardcoded secret value.", [key]),
        "remediation": "Move sensitive values to Terraform variables or a secrets manager (AWS Secrets Manager, Vault).",
        "confidence": 0.85,
    }
}
```

- [ ] **Step 4: Create kubernetes/pod_security.rego**

```rego
# ui/security/opa/policies/kubernetes/pod_security.rego
package kubernetes.pod_security

import future.keywords.if
import future.keywords.contains

pod_types := {"Pod", "Deployment", "DaemonSet", "StatefulSet", "ReplicaSet"}

findings contains finding if {
    resource := input.resource
    resource.tool == "kubernetes"
    pod_types[resource.type]
    containers := get_containers(resource)
    container := containers[_]
    sc := container.securityContext
    sc.privileged == true
    finding := {
        "id": "K8S-POD-001",
        "severity": "critical",
        "category": "runtime",
        "resource": concat("/", [resource.namespace, resource.name]),
        "location": resource.location,
        "title": "Container running in privileged mode",
        "description": sprintf("Container '%v' has securityContext.privileged=true, granting host-level access.", [container.name]),
        "remediation": "Remove privileged: true from securityContext. Use specific capabilities if needed.",
        "confidence": 1.0,
    }
}

findings contains finding if {
    resource := input.resource
    resource.tool == "kubernetes"
    pod_types[resource.type]
    containers := get_containers(resource)
    container := containers[_]
    sc := container.securityContext
    sc.runAsUser == 0
    finding := {
        "id": "K8S-POD-002",
        "severity": "high",
        "category": "runtime",
        "resource": concat("/", [resource.namespace, resource.name]),
        "location": resource.location,
        "title": "Container running as root (UID 0)",
        "description": sprintf("Container '%v' has runAsUser=0.", [container.name]),
        "remediation": "Set runAsUser to a non-zero UID and runAsNonRoot: true.",
        "confidence": 1.0,
    }
}

get_containers(resource) := containers if {
    resource.type == "Pod"
    containers := resource.attributes.spec.containers
} else := containers if {
    containers := resource.attributes.spec.template.spec.containers
}
```

- [ ] **Step 5: Create kubernetes/rbac.rego**

```rego
# ui/security/opa/policies/kubernetes/rbac.rego
package kubernetes.rbac

import future.keywords.if
import future.keywords.contains

rbac_types := {"ClusterRole", "Role"}

findings contains finding if {
    resource := input.resource
    resource.tool == "kubernetes"
    rbac_types[resource.type]
    rule := resource.attributes.rules[_]
    rule.verbs[_] == "*"
    finding := {
        "id": "K8S-RBAC-001",
        "severity": "high",
        "category": "iam",
        "resource": concat("/", [resource.namespace, resource.name]),
        "location": resource.location,
        "title": "RBAC rule uses wildcard verb",
        "description": "A RBAC rule grants wildcard (*) verbs, allowing any action on matched resources.",
        "remediation": "Replace * verbs with specific operations (get, list, watch) following least-privilege.",
        "confidence": 1.0,
    }
}

findings contains finding if {
    resource := input.resource
    resource.tool == "kubernetes"
    rbac_types[resource.type]
    rule := resource.attributes.rules[_]
    rule.resources[_] == "*"
    finding := {
        "id": "K8S-RBAC-002",
        "severity": "high",
        "category": "iam",
        "resource": concat("/", [resource.namespace, resource.name]),
        "location": resource.location,
        "title": "RBAC rule uses wildcard resource",
        "description": "A RBAC rule grants access to all resources (*), violating least-privilege.",
        "remediation": "Replace * resources with specific resource types.",
        "confidence": 1.0,
    }
}
```

- [ ] **Step 6: Create kubernetes/secrets.rego**

```rego
# ui/security/opa/policies/kubernetes/secrets.rego
package kubernetes.secrets

import future.keywords.if
import future.keywords.contains

secret_patterns := {"password", "token", "secret", "key", "api_key", "apikey"}

findings contains finding if {
    resource := input.resource
    resource.tool == "kubernetes"
    resource.type == "ConfigMap"
    data := resource.attributes.data
    key := secret_patterns[_]
    data[key]
    finding := {
        "id": "K8S-SEC-001",
        "severity": "high",
        "category": "secrets",
        "resource": concat("/", [resource.namespace, resource.name]),
        "location": resource.location,
        "title": sprintf("Sensitive key '%v' found in ConfigMap", [key]),
        "description": "ConfigMaps are not encrypted at rest. Secrets should be stored in Kubernetes Secrets or external secret managers.",
        "remediation": "Move sensitive values to a Kubernetes Secret or use an external secret manager (Vault, AWS Secrets Manager).",
        "confidence": 0.9,
    }
}

findings contains finding if {
    resource := input.resource
    resource.tool == "kubernetes"
    resource.type == "Secret"
    sd := resource.attributes.stringData
    key := secret_patterns[_]
    val := sd[key]
    count(val) > 4
    finding := {
        "id": "K8S-SEC-002",
        "severity": "medium",
        "category": "secrets",
        "resource": concat("/", [resource.namespace, resource.name]),
        "location": resource.location,
        "title": "Secret contains plaintext value in stringData",
        "description": "Using stringData stores values in plaintext in the manifest. Consider using an external secret operator.",
        "remediation": "Use an external secrets operator (External Secrets Operator, Sealed Secrets) to avoid storing secrets in manifests.",
        "confidence": 0.8,
    }
}
```

- [ ] **Step 7: Create kubernetes/network_policy.rego**

```rego
# ui/security/opa/policies/kubernetes/network_policy.rego
package kubernetes.network_policy

import future.keywords.if
import future.keywords.contains

# Flag namespaces with no NetworkPolicy (heuristic: resource has no ingress/egress rules)
findings contains finding if {
    resource := input.resource
    resource.tool == "kubernetes"
    resource.type == "NetworkPolicy"
    spec := resource.attributes.spec
    not spec.ingress
    not spec.egress
    finding := {
        "id": "K8S-NET-001",
        "severity": "medium",
        "category": "network",
        "resource": concat("/", [resource.namespace, resource.name]),
        "location": resource.location,
        "title": "NetworkPolicy has no ingress or egress rules",
        "description": "A NetworkPolicy with no ingress or egress rules provides no actual restriction.",
        "remediation": "Define explicit ingress and egress rules. Add a default-deny policy to the namespace.",
        "confidence": 1.0,
    }
}
```

- [ ] **Step 8: Create kubevirt/vm_security.rego**

```rego
# ui/security/opa/policies/kubevirt/vm_security.rego
package kubevirt.vm_security

import future.keywords.if
import future.keywords.contains

vm_types := {"VirtualMachine", "VirtualMachineInstanceTemplate"}

findings contains finding if {
    resource := input.resource
    resource.tool == "kubevirt"
    vm_types[resource.type]
    domain := resource.attributes.spec.template.spec.domain
    not domain.resources.limits
    finding := {
        "id": "KV-VM-001",
        "severity": "medium",
        "category": "runtime",
        "resource": concat("/", [resource.namespace, resource.name]),
        "location": resource.location,
        "title": "VM template missing resource limits",
        "description": "VirtualMachine has no CPU/memory limits defined, risking resource exhaustion.",
        "remediation": "Set spec.template.spec.domain.resources.limits with cpu and memory values.",
        "confidence": 1.0,
    }
}
```

- [ ] **Step 9: Create ansible/privilege_escalation.rego**

```rego
# ui/security/opa/policies/ansible/privilege_escalation.rego
package ansible.privilege_escalation

import future.keywords.if
import future.keywords.contains

findings contains finding if {
    resource := input.resource
    resource.tool == "ansible"
    resource.type == "task"
    resource.attributes.become == true
    not resource.attributes.become_user
    finding := {
        "id": "ANS-PRIV-001",
        "severity": "medium",
        "category": "iam",
        "resource": resource.name,
        "location": resource.location,
        "title": "Ansible task uses become without specifying become_user",
        "description": "Using become without become_user defaults to root escalation.",
        "remediation": "Specify become_user with the minimum required user instead of defaulting to root.",
        "confidence": 1.0,
    }
}

findings contains finding if {
    resource := input.resource
    resource.tool == "ansible"
    resource.type == "task"
    shell_modules := {"shell", "command", "raw"}
    some mod in shell_modules
    cmd := resource.attributes[mod]
    is_string(cmd)
    contains(cmd, "{{")
    not contains(cmd, "| quote")
    finding := {
        "id": "ANS-PRIV-002",
        "severity": "high",
        "category": "secrets",
        "resource": resource.name,
        "location": resource.location,
        "title": "Unsafe Jinja2 variable in shell command",
        "description": "A Jinja2 variable is used directly in a shell command without the quote filter, risking injection.",
        "remediation": "Apply the | quote filter to all variables used in shell/command/raw tasks.",
        "confidence": 0.9,
    }
}
```

- [ ] **Step 10: Create registry/registry.rego**

```rego
# ui/security/opa/policies/registry/registry.rego
package registry.images

import future.keywords.if
import future.keywords.contains

findings contains finding if {
    resource := input.resource
    resource.tool == "registry"
    resource.attributes.is_mutable_tag == true
    finding := {
        "id": "REG-001",
        "severity": "medium",
        "category": "exposure",
        "resource": resource.name,
        "location": resource.location,
        "title": "Image uses mutable 'latest' tag without digest pinning",
        "description": "Using the 'latest' tag without a digest allows the image to change silently.",
        "remediation": "Pin images to a specific digest (image@sha256:...) or use an immutable tag.",
        "confidence": 1.0,
    }
}
```

- [ ] **Step 11: Create representative AWS policies (cloudtrail + guardduty)**

```rego
# ui/security/opa/policies/terraform/aws/cloudtrail.rego
package terraform.aws.cloudtrail

import future.keywords.if
import future.keywords.contains

findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_cloudtrail"
    resource.attributes.enable_logging == false
    finding := {
        "id": "AWS-CT-001",
        "severity": "high",
        "category": "observability",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "CloudTrail logging is disabled",
        "description": "The CloudTrail trail has enable_logging=false, resulting in no audit trail.",
        "remediation": "Set enable_logging = true on the aws_cloudtrail resource.",
        "confidence": 1.0,
    }
}

findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_cloudtrail"
    not resource.attributes.log_file_validation_enabled
    finding := {
        "id": "AWS-CT-002",
        "severity": "medium",
        "category": "observability",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "CloudTrail log file validation not enabled",
        "description": "Without log file validation, log files could be tampered with undetected.",
        "remediation": "Set log_file_validation_enabled = true.",
        "confidence": 1.0,
    }
}
```

```rego
# ui/security/opa/policies/terraform/aws/guardduty.rego
package terraform.aws.guardduty

import future.keywords.if
import future.keywords.contains

findings contains finding if {
    resource := input.resource
    resource.tool == "terraform"
    resource.type == "aws_guardduty_detector"
    resource.attributes.enable == false
    finding := {
        "id": "AWS-GD-001",
        "severity": "high",
        "category": "observability",
        "resource": concat(".", [resource.type, resource.name]),
        "location": resource.location,
        "title": "GuardDuty detector is disabled",
        "description": "GuardDuty is not enabled for this region, disabling threat detection.",
        "remediation": "Set enable = true on the aws_guardduty_detector resource.",
        "confidence": 1.0,
    }
}
```

> Create the remaining 11 AWS policy files (`cloudwatch.rego`, `config.rego`, `vpc.rego`, `kms.rego`, `s3.rego`, `rds.rego`, `lambda.rego`, `eks.rego`, `ecr.rego`, `iam.rego`, `securityhub.rego`) following the same pattern: detect a specific misconfiguration in the relevant `aws_*` resource type, emit a finding with a unique ID (`AWS-<SERVICE>-<NUM>`), severity, and remediation.

- [ ] **Step 12: Run all tests**

```bash
cd ui/security && go test ./... -v 2>&1 | tail -30
```
Expected: all PASS

- [ ] **Step 13: Commit**

```bash
git add ui/security/opa/policies/
git commit -m "feat(security): add OPA policies for all supported tools"
```

---

## Task 9: Backend proxy

**Files:**
- Create: `ui/backend/handlers/security.go`
- Modify: `ui/backend/main.go`

- [ ] **Step 1: Create handlers/security.go**

```go
// ui/backend/handlers/security.go
package handlers

import (
	"fmt"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
)

// NewSecurityProxy returns an http.Handler that reverse-proxies to the security agent.
// It strips the /api/v1/security prefix before forwarding.
func NewSecurityProxy() http.Handler {
	agentURL := os.Getenv("SECURITY_AGENT_URL")
	if agentURL == "" {
		agentURL = "http://security-agent.kubeui.svc.cluster.local:8082"
	}

	target, err := url.Parse(agentURL)
	if err != nil {
		panic(fmt.Sprintf("invalid SECURITY_AGENT_URL: %v", err))
	}

	proxy := httputil.NewSingleHostReverseProxy(target)

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Strip /api/v1/security prefix so the agent sees /scan, /rules, /healthz
		r.URL.Path = strings.TrimPrefix(r.URL.Path, "/api/v1/security")
		if r.URL.Path == "" {
			r.URL.Path = "/"
		}
		r.URL.RawPath = strings.TrimPrefix(r.URL.RawPath, "/api/v1/security")
		proxy.ServeHTTP(w, r)
	})
}
```

- [ ] **Step 2: Register route in main.go**

In `ui/backend/main.go`, after the `// Health check` block, add:

```go
// Security agent proxy
mux.Handle("/api/v1/security/", handlers.NewSecurityProxy())
```

- [ ] **Step 3: Verify backend compiles**

```bash
cd ui/backend && go build . && echo "BUILD OK"
```
Expected: `BUILD OK`

- [ ] **Step 4: Commit**

```bash
git add ui/backend/handlers/security.go ui/backend/main.go
git commit -m "feat(backend): add security agent proxy handler"
```

---

## Task 10: Frontend types and API

**Files:**
- Modify: `ui/frontend/src/lib/types.ts`
- Modify: `ui/frontend/src/lib/api.ts`

- [ ] **Step 1: Add types to types.ts**

Append to the end of `ui/frontend/src/lib/types.ts`:

```typescript
export interface SecurityLocation {
  line: number;
  column: number;
}

export interface Finding {
  id: string;
  severity: 'critical' | 'high' | 'medium' | 'low';
  category: string;
  resource: string;
  location: SecurityLocation;
  title: string;
  description: string;
  remediation: string;
  confidence: number;
}

export interface ScanRequest {
  tool: 'terraform' | 'kubernetes' | 'ansible' | 'kubevirt';
  content: string;
  filename: string;
  llm_enrich: boolean;
}

export interface ScanResult {
  tool: string;
  filename: string;
  findings: Finding[];
  scanned_at: string;
  duration_ms: number;
}

export interface RegistryScanRequest {
  registry_url: string;
  insecure: boolean;
  username?: string;
  password?: string;
  llm_enrich: boolean;
}

export interface RegistryScanResult {
  registry_url: string;
  images_scanned: number;
  findings: Finding[];
  scanned_at: string;
  duration_ms: number;
}

export interface RuleInfo {
  id: string;
  policy: string;
  title: string;
  severity: string;
  tool: string;
}

export interface RulesResponse {
  rules: RuleInfo[];
  total: number;
}
```

- [ ] **Step 2: Add API functions to api.ts**

Append to the `api` object in `ui/frontend/src/lib/api.ts` (before the closing `}`):

```typescript
  scanIaC: (req: ScanRequest) =>
    fetch(`${BASE}/security/scan`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req),
    }).then((r) => {
      if (!r.ok) throw new Error(`Scan error: ${r.status}`);
      return r.json() as Promise<ScanResult>;
    }),

  scanRegistry: (req: RegistryScanRequest) =>
    fetch(`${BASE}/security/scan/registry`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(req),
    }).then((r) => {
      if (!r.ok) throw new Error(`Registry scan error: ${r.status}`);
      return r.json() as Promise<RegistryScanResult>;
    }),

  getSecurityRules: () => fetchJSON<RulesResponse>(`${BASE}/security/rules`),
```

Also add the new types to the import at line 1 of `api.ts`:
```typescript
import type { ..., ScanRequest, ScanResult, RegistryScanRequest, RegistryScanResult, RulesResponse } from './types';
```

- [ ] **Step 3: Verify TypeScript compiles**

```bash
cd ui/frontend && npx tsc --noEmit 2>&1 | head -20
```
Expected: no errors

- [ ] **Step 4: Commit**

```bash
git add ui/frontend/src/lib/types.ts ui/frontend/src/lib/api.ts
git commit -m "feat(frontend): add security types and API functions"
```

---

## Task 11: Frontend UI components

**Files:**
- Create: `ui/frontend/src/components/security/SeverityBadge.tsx`
- Create: `ui/frontend/src/components/security/FindingDetail.tsx`
- Create: `ui/frontend/src/components/security/FindingsList.tsx`
- Create: `ui/frontend/src/components/security/ScanUpload.tsx`
- Create: `ui/frontend/src/components/security/RegistryScan.tsx`
- Create: `ui/frontend/src/components/sre/SecurityScanner.tsx`

- [ ] **Step 1: Create SeverityBadge.tsx**

```tsx
// ui/frontend/src/components/security/SeverityBadge.tsx
import { cn } from '@/lib/utils';

const colors: Record<string, string> = {
  critical: 'bg-red-100 text-red-800 border-red-200',
  high:     'bg-orange-100 text-orange-800 border-orange-200',
  medium:   'bg-yellow-100 text-yellow-800 border-yellow-200',
  low:      'bg-blue-100 text-blue-800 border-blue-200',
};

export function SeverityBadge({ severity }: { severity: string }) {
  return (
    <span className={cn('inline-flex items-center rounded border px-2 py-0.5 text-xs font-medium', colors[severity] ?? 'bg-gray-100 text-gray-800')}>
      {severity.toUpperCase()}
    </span>
  );
}
```

- [ ] **Step 2: Create FindingDetail.tsx**

```tsx
// ui/frontend/src/components/security/FindingDetail.tsx
import { ArrowLeft } from 'lucide-react';
import type { Finding } from '@/lib/types';
import { SeverityBadge } from './SeverityBadge';

interface FindingDetailProps {
  finding: Finding;
  onBack: () => void;
}

export function FindingDetail({ finding, onBack }: FindingDetailProps) {
  return (
    <div className="space-y-6 p-6">
      <button
        onClick={onBack}
        className="flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground"
      >
        <ArrowLeft className="h-4 w-4" />
        Back to findings
      </button>

      <div className="space-y-2">
        <div className="flex items-center gap-3">
          <SeverityBadge severity={finding.severity} />
          <span className="text-xs text-muted-foreground font-mono">{finding.id}</span>
        </div>
        <h2 className="text-2xl font-bold">{finding.title}</h2>
        <p className="text-sm text-muted-foreground">
          Resource: <span className="font-mono">{finding.resource}</span>
          {finding.location.line > 0 && (
            <span> · Line {finding.location.line}</span>
          )}
        </p>
      </div>

      <div className="space-y-4">
        <section>
          <h3 className="text-sm font-semibold mb-1">Description</h3>
          <p className="text-sm text-muted-foreground">{finding.description}</p>
        </section>

        <section>
          <h3 className="text-sm font-semibold mb-1">Remediation</h3>
          <p className="text-sm text-muted-foreground">{finding.remediation}</p>
        </section>

        <section>
          <h3 className="text-sm font-semibold mb-1">Details</h3>
          <dl className="text-sm space-y-1">
            <div className="flex gap-2">
              <dt className="text-muted-foreground w-24">Category</dt>
              <dd className="font-mono">{finding.category}</dd>
            </div>
            <div className="flex gap-2">
              <dt className="text-muted-foreground w-24">Confidence</dt>
              <dd>{(finding.confidence * 100).toFixed(0)}%</dd>
            </div>
          </dl>
        </section>
      </div>
    </div>
  );
}
```

- [ ] **Step 3: Create FindingsList.tsx**

```tsx
// ui/frontend/src/components/security/FindingsList.tsx
import { useState } from 'react';
import type { Finding } from '@/lib/types';
import { SeverityBadge } from './SeverityBadge';
import { FindingDetail } from './FindingDetail';

const severityOrder = ['critical', 'high', 'medium', 'low'];

interface FindingsListProps {
  findings: Finding[];
  durationMs: number;
}

export function FindingsList({ findings, durationMs }: FindingsListProps) {
  const [selected, setSelected] = useState<Finding | null>(null);
  const [filter, setFilter] = useState<string>('all');

  if (selected) {
    return <FindingDetail finding={selected} onBack={() => setSelected(null)} />;
  }

  const filtered = filter === 'all'
    ? findings
    : findings.filter((f) => f.severity === filter);

  const sorted = [...filtered].sort(
    (a, b) => severityOrder.indexOf(a.severity) - severityOrder.indexOf(b.severity)
  );

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <p className="text-sm text-muted-foreground">
          {findings.length} finding{findings.length !== 1 ? 's' : ''} · {durationMs}ms
        </p>
        <div className="flex gap-2">
          {['all', ...severityOrder].map((s) => (
            <button
              key={s}
              onClick={() => setFilter(s)}
              className={`text-xs px-2 py-1 rounded ${filter === s ? 'bg-accent text-accent-foreground' : 'text-muted-foreground hover:text-foreground'}`}
            >
              {s}
            </button>
          ))}
        </div>
      </div>

      {sorted.length === 0 ? (
        <p className="text-sm text-muted-foreground py-8 text-center">No findings for this filter.</p>
      ) : (
        <div className="divide-y divide-border rounded-md border">
          {sorted.map((f, i) => (
            <button
              key={i}
              onClick={() => setSelected(f)}
              className="w-full flex items-center gap-4 px-4 py-3 text-left hover:bg-accent/50 transition-colors"
            >
              <SeverityBadge severity={f.severity} />
              <div className="flex-1 min-w-0">
                <p className="text-sm font-medium truncate">{f.title}</p>
                <p className="text-xs text-muted-foreground font-mono truncate">{f.resource}</p>
              </div>
              <span className="text-xs text-muted-foreground font-mono shrink-0">{f.id}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}
```

- [ ] **Step 4: Create ScanUpload.tsx**

```tsx
// ui/frontend/src/components/security/ScanUpload.tsx
import { useState } from 'react';
import { Upload } from 'lucide-react';
import { api } from '@/lib/api';
import type { ScanResult, ScanRequest } from '@/lib/types';

const TOOLS = [
  { value: 'terraform', label: 'Terraform (.tf, plan.json)' },
  { value: 'kubernetes', label: 'Kubernetes (YAML)' },
  { value: 'ansible', label: 'Ansible Playbook' },
  { value: 'kubevirt', label: 'KubeVirt VM Template' },
] as const;

interface ScanUploadProps {
  onResult: (result: ScanResult) => void;
}

export function ScanUpload({ onResult }: ScanUploadProps) {
  const [tool, setTool] = useState<ScanRequest['tool']>('terraform');
  const [content, setContent] = useState('');
  const [filename, setFilename] = useState('main.tf');
  const [llmEnrich, setLlmEnrich] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleFileChange = (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0];
    if (!file) return;
    setFilename(file.name);
    file.text().then(setContent);
  };

  const handleScan = async () => {
    if (!content.trim()) { setError('Paste or upload content first.'); return; }
    setLoading(true); setError('');
    try {
      const result = await api.scanIaC({ tool, content, filename, llm_enrich: llmEnrich });
      onResult(result);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="space-y-4">
      <div className="flex gap-3 flex-wrap">
        {TOOLS.map((t) => (
          <button
            key={t.value}
            onClick={() => setTool(t.value)}
            className={`text-sm px-3 py-1.5 rounded border transition-colors ${tool === t.value ? 'bg-accent text-accent-foreground border-accent' : 'border-border text-muted-foreground hover:border-foreground'}`}
          >
            {t.label}
          </button>
        ))}
      </div>

      <textarea
        value={content}
        onChange={(e) => setContent(e.target.value)}
        placeholder="Paste IaC content here..."
        className="w-full h-48 font-mono text-sm p-3 rounded-md border border-border bg-background resize-none focus:outline-none focus:ring-1 focus:ring-ring"
      />

      <div className="flex items-center justify-between gap-4">
        <label className="flex items-center gap-2 text-sm cursor-pointer">
          <Upload className="h-4 w-4 text-muted-foreground" />
          <span className="text-muted-foreground">Or upload file:</span>
          <input type="file" className="hidden" onChange={handleFileChange} />
          {filename && <span className="font-mono text-xs">{filename}</span>}
        </label>
        <label className="flex items-center gap-2 text-sm cursor-pointer">
          <input type="checkbox" checked={llmEnrich} onChange={(e) => setLlmEnrich(e.target.checked)} />
          <span className="text-muted-foreground">LLM enrichment</span>
        </label>
        <button
          onClick={handleScan}
          disabled={loading}
          className="px-4 py-2 text-sm bg-primary text-primary-foreground rounded-md hover:bg-primary/90 disabled:opacity-50"
        >
          {loading ? 'Scanning...' : 'Scan'}
        </button>
      </div>

      {error && <p className="text-sm text-destructive">{error}</p>}
    </div>
  );
}
```

- [ ] **Step 5: Create RegistryScan.tsx**

```tsx
// ui/frontend/src/components/security/RegistryScan.tsx
import { useState } from 'react';
import { api } from '@/lib/api';
import type { RegistryScanResult } from '@/lib/types';

interface RegistryScanProps {
  onResult: (result: RegistryScanResult) => void;
}

export function RegistryScan({ onResult }: RegistryScanProps) {
  const [url, setUrl] = useState('172.18.0.2:5000');
  const [insecure, setInsecure] = useState(true);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const handleScan = async () => {
    setLoading(true); setError('');
    try {
      const result = await api.scanRegistry({ registry_url: url, insecure, llm_enrich: false });
      onResult(result);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="space-y-3">
      <div className="flex gap-3 items-center">
        <input
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          placeholder="registry:port"
          className="flex-1 text-sm font-mono px-3 py-2 rounded-md border border-border bg-background focus:outline-none focus:ring-1 focus:ring-ring"
        />
        <label className="flex items-center gap-2 text-sm cursor-pointer">
          <input type="checkbox" checked={insecure} onChange={(e) => setInsecure(e.target.checked)} />
          <span className="text-muted-foreground">Insecure (HTTP)</span>
        </label>
        <button
          onClick={handleScan}
          disabled={loading}
          className="px-4 py-2 text-sm bg-primary text-primary-foreground rounded-md hover:bg-primary/90 disabled:opacity-50"
        >
          {loading ? 'Scanning...' : 'Scan Registry'}
        </button>
      </div>
      {error && <p className="text-sm text-destructive">{error}</p>}
    </div>
  );
}
```

- [ ] **Step 6: Create SecurityScanner.tsx (main SRE entry point)**

```tsx
// ui/frontend/src/components/sre/SecurityScanner.tsx
import { useState } from 'react';
import { Shield } from 'lucide-react';
import { ScanUpload } from '@/components/security/ScanUpload';
import { RegistryScan } from '@/components/security/RegistryScan';
import { FindingsList } from '@/components/security/FindingsList';
import type { ScanResult, RegistryScanResult } from '@/lib/types';

type ScanMode = 'iac' | 'registry';

export function SecurityScanner() {
  const [mode, setMode] = useState<ScanMode>('iac');
  const [iacResult, setIacResult] = useState<ScanResult | null>(null);
  const [regResult, setRegResult] = useState<RegistryScanResult | null>(null);

  const activeFindings = mode === 'iac' ? iacResult?.findings ?? null : regResult?.findings ?? null;
  const activeDuration = mode === 'iac' ? iacResult?.duration_ms ?? 0 : regResult?.duration_ms ?? 0;

  return (
    <div className="space-y-6 p-6">
      <div className="flex items-center gap-3">
        <Shield className="h-6 w-6 text-muted-foreground" />
        <h2 className="text-2xl font-bold">Security Scanner</h2>
      </div>

      <div className="flex gap-3 border-b border-border pb-3">
        <button
          onClick={() => setMode('iac')}
          className={`text-sm px-3 py-1.5 rounded transition-colors ${mode === 'iac' ? 'bg-accent text-accent-foreground' : 'text-muted-foreground hover:text-foreground'}`}
        >
          IaC File
        </button>
        <button
          onClick={() => setMode('registry')}
          className={`text-sm px-3 py-1.5 rounded transition-colors ${mode === 'registry' ? 'bg-accent text-accent-foreground' : 'text-muted-foreground hover:text-foreground'}`}
        >
          Container Registry
        </button>
      </div>

      {mode === 'iac' ? (
        <ScanUpload onResult={setIacResult} />
      ) : (
        <RegistryScan onResult={setRegResult} />
      )}

      {activeFindings !== null && (
        <FindingsList findings={activeFindings} durationMs={activeDuration} />
      )}
    </div>
  );
}
```

- [ ] **Step 7: Verify TypeScript compiles**

```bash
cd ui/frontend && npx tsc --noEmit 2>&1 | head -20
```
Expected: no errors

- [ ] **Step 8: Commit**

```bash
git add ui/frontend/src/components/security/ ui/frontend/src/components/sre/SecurityScanner.tsx
git commit -m "feat(frontend): add security scanner UI components"
```

---

## Task 12: Wire Security into SRE sidebar and dashboard

**Files:**
- Modify: `ui/frontend/src/components/layout/Sidebar.tsx`
- Modify: `ui/frontend/src/pages/SREDashboard.tsx`

- [ ] **Step 1: Add Security to Sidebar.tsx**

In `ui/frontend/src/components/layout/Sidebar.tsx`:

1. Add `ShieldAlert` to the lucide-react import on line 1:
```typescript
import { LayoutDashboard, Server, Box, Monitor, CalendarClock, Layers, HardDrive, Database, ShieldAlert } from 'lucide-react';
```

2. Add to the `navItems` array (after `'images'`):
```typescript
{ label: 'Security', icon: ShieldAlert, path: 'security' },
```

- [ ] **Step 2: Add case to SREDashboard.tsx**

In `ui/frontend/src/pages/SREDashboard.tsx`:

1. Add import at the top:
```typescript
import { SecurityScanner } from '@/components/sre/SecurityScanner';
```

2. Add case before `default:`:
```typescript
case 'security':
  return <SecurityScanner />;
```

- [ ] **Step 3: Verify TypeScript compiles**

```bash
cd ui/frontend && npx tsc --noEmit 2>&1 | head -20
```
Expected: no errors

- [ ] **Step 4: Start the dev server and manually verify**

```bash
cd ui/frontend && npm run dev &
# Open http://localhost:5173, switch to SRE mode, verify "Security" appears in sidebar
# Click Security, verify the scanner UI loads
```

- [ ] **Step 5: Commit**

```bash
git add ui/frontend/src/components/layout/Sidebar.tsx ui/frontend/src/pages/SREDashboard.tsx
git commit -m "feat(frontend): wire Security Scanner into SRE sidebar and dashboard"
```

---

## Task 13: Kubernetes deployment manifests

**Files:**
- Create: `ui/k8s/security-agent.yaml`
- Modify: `ui/k8s/kubeui.yaml`

- [ ] **Step 1: Create ui/k8s/security-agent.yaml**

```yaml
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: security-agent
  namespace: kubeui
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: security-agent
  namespace: kubeui
  labels:
    app: security-agent
spec:
  replicas: 1
  selector:
    matchLabels:
      app: security-agent
  template:
    metadata:
      labels:
        app: security-agent
    spec:
      serviceAccountName: security-agent
      containers:
        - name: security-agent
          image: 172.18.0.2:5000/security-agent:latest
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 8082
              name: http
          env:
            - name: OPA_POLICIES_DIR
              value: "/policies"
            - name: OLLAMA_URL
              value: "http://localhost:11434"
            - name: OLLAMA_MODEL
              value: "llama3"
          volumeMounts:
            - name: policies
              mountPath: /policies
              readOnly: true
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 512Mi
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 15
      volumes:
        - name: policies
          configMap:
            name: security-agent-policies
---
apiVersion: v1
kind: Service
metadata:
  name: security-agent
  namespace: kubeui
spec:
  selector:
    app: security-agent
  ports:
    - name: http
      port: 8082
      targetPort: http
  type: ClusterIP
```

> **Note:** The `security-agent-policies` ConfigMap is generated by `build-security-agent.sh` (Task 14). Keys are flattened with `__` separating path segments (e.g., `terraform__aws__cloudtrail.rego`). The OPA evaluator uses the `package` declaration inside each file to derive the correct query path — not the filename — so flattened keys are handled correctly.

- [ ] **Step 2: Add SECURITY_AGENT_URL env to kubeui.yaml**

In `ui/k8s/kubeui.yaml`, find the `kubeui-backend` Deployment's `env:` block (around line 69) and add:

```yaml
          - name: SECURITY_AGENT_URL
            value: "http://security-agent.kubeui.svc.cluster.local:8082"
```

- [ ] **Step 3: Commit**

```bash
git add ui/k8s/security-agent.yaml ui/k8s/kubeui.yaml
git commit -m "feat(k8s): add security-agent deployment and update kubeui env"
```

---

## Task 14: Makefile, run-ui.sh, and build script

**Files:**
- Modify: `Makefile`
- Modify: `run-ui.sh`
- Create: `ui/k8s/build-security-agent.sh`

- [ ] **Step 1: Update Makefile**

In `Makefile`:

1. Update the `.PHONY` line (line 1) to add `security ui-security`:
```makefile
.PHONY: all prereqs metallb capi-init target-cluster target-cluster-lite target-cluster-full verify clean ui ui-build registry bake-image demo help pre-pull istio security ui-security
```

2. Extend the `ui-build` target:
```makefile
ui-build:
	cd ui/frontend && npm install && npm run build
	cd ui/backend && go build -o ../dist/backend .
	cd ui/security && go build -o ../dist/security-agent .
	@echo "UI built to ui/dist/"
```

3. Add new targets after the `ui-build` target:
```makefile
security:       ## Run security agent locally (port 8082)
	cd ui/security && OPA_POLICIES_DIR=opa/policies go run .

ui-security:    ## Run full stack: backend + frontend + security agent
	make -j3 ui security
```

4. Add help text in the `help` target under `Web UI:`:
```makefile
	@echo "  make security       - Run the security agent (port 8082)"
	@echo "  make ui-security    - Run full stack including security agent"
```

- [ ] **Step 2: Update run-ui.sh**

In `run-ui.sh`, add `SECURITY_AGENT_URL` to the inline env block on the `go run .` invocation (lines 26-32). The block should become:

```bash
KAGENT_AGENT_URL="$KAGENT_AGENT_URL" \
KAGENT_CONTROLLER_URL="$KAGENT_CONTROLLER_URL" \
KAGENT_AGENT_NAME="$KAGENT_AGENT" \
KAGENT_AGENT_NAMESPACE="$KAGENT_NS" \
KAGENT_AGENT_URL_TARGET_CLUSTER_AGENT="$KAGENT_AGENT_URL_TARGET_CLUSTER_AGENT" \
CLAUDE_DIR="$SCRIPT_DIR" \
SECURITY_AGENT_URL="${SECURITY_AGENT_URL:-http://localhost:8082}" \
go run . &
```

- [ ] **Step 3: Create ui/k8s/build-security-agent.sh**

```bash
#!/usr/bin/env bash
# Build and push the security-agent container image, then generate the policies ConfigMap.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECURITY_DIR="$SCRIPT_DIR/../security"
REGISTRY="172.18.0.2:5000"
IMAGE="$REGISTRY/security-agent:latest"

echo "Building security-agent binary..."
cd "$SECURITY_DIR"
CGO_ENABLED=0 GOOS=linux go build -o /tmp/security-agent-bin .

echo "Building container image $IMAGE..."
cat > /tmp/Dockerfile.security-agent << 'EOF'
FROM gcr.io/distroless/static-debian12
COPY security-agent-bin /security-agent
EXPOSE 8082
ENTRYPOINT ["/security-agent"]
EOF
cp /tmp/security-agent-bin /tmp/
docker build -f /tmp/Dockerfile.security-agent -t "$IMAGE" /tmp/
docker push "$IMAGE"
echo "Pushed $IMAGE"

echo "Generating policies ConfigMap (recursive, flattened keys)..."
# kubectl --from-file only reads flat directories; we flatten the tree with __ as separator.
# e.g. terraform/aws/cloudtrail.rego → key "terraform__aws__cloudtrail.rego"
CM_ARGS=""
while IFS= read -r -d '' filepath; do
  relpath="${filepath#$SECURITY_DIR/opa/policies/}"
  key="${relpath//\//__}"   # replace / with __
  CM_ARGS="$CM_ARGS --from-file=${key}=${filepath}"
done < <(find "$SECURITY_DIR/opa/policies" -name "*.rego" -print0)

# shellcheck disable=SC2086
kubectl create configmap security-agent-policies \
  $CM_ARGS \
  --namespace=kubeui \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ConfigMap security-agent-policies updated with $(find "$SECURITY_DIR/opa/policies" -name "*.rego" | wc -l) policies"

echo "Applying security-agent.yaml..."
kubectl apply -f "$SCRIPT_DIR/security-agent.yaml"

echo "Done. security-agent deployed to kubeui namespace."
```

```bash
chmod +x ui/k8s/build-security-agent.sh
```

- [ ] **Step 4: Verify Makefile syntax**

```bash
make -n security 2>&1
make -n ui-build 2>&1
```
Expected: shows commands without errors

- [ ] **Step 5: Commit**

```bash
git add Makefile run-ui.sh ui/k8s/build-security-agent.sh
git commit -m "feat: add security agent Makefile targets and build script"
```

---

## Task 15: End-to-end smoke test

- [ ] **Step 1: Start the security agent locally**

```bash
cd ui/security && OPA_POLICIES_DIR=opa/policies go run . &
SECURITY_PID=$!
sleep 2
```

- [ ] **Step 2: Test /healthz**

```bash
curl -s http://localhost:8082/healthz
```
Expected: `ok`

- [ ] **Step 3: Test /rules**

```bash
curl -s http://localhost:8082/rules | jq '.total'
```
Expected: a positive integer (number of loaded policies)

- [ ] **Step 4: Test /scan with a Terraform misconfiguration**

```bash
curl -s -X POST http://localhost:8082/scan \
  -H 'Content-Type: application/json' \
  -d '{
    "tool": "terraform",
    "filename": "main.tf",
    "content": "resource \"aws_security_group\" \"web\" {\n  ingress {\n    cidr_blocks = [\"0.0.0.0/0\"]\n    from_port = 0\n    to_port = 0\n  }\n}",
    "llm_enrich": false
  }' | jq '.findings | length'
```
Expected: `1` or more (TF-NET-001 must appear)

- [ ] **Step 5: Test /scan/registry against the local registry**

```bash
curl -s -X POST http://localhost:8082/scan/registry \
  -H 'Content-Type: application/json' \
  -d '{"registry_url":"172.18.0.2:5000","insecure":true,"llm_enrich":false}' \
  | jq '.images_scanned'
```
Expected: a non-negative integer

- [ ] **Step 6: Test backend proxy (requires backend running)**

```bash
# In a separate terminal: cd ui/backend && go run .
curl -s http://localhost:8080/api/v1/security/healthz
```
Expected: `ok`

- [ ] **Step 7: Kill the security agent**

```bash
kill $SECURITY_PID
```

- [ ] **Step 8: Final commit**

```bash
git status  # review any untracked files before staging
git add ui/security/ ui/backend/ ui/frontend/src/ ui/k8s/ Makefile run-ui.sh
git commit -m "feat: IaC Security Agent — complete implementation"
```

---

## Summary of Commits

1. `feat(security): scaffold module and domain types`
2. `feat(security): add OPA evaluator and seed network policy`
3. `feat(security): add Terraform HCL parser`
4. `feat(security): add Kubernetes YAML parser`
5. `feat(security): add KubeVirt, Ansible, and Registry parsers`
6. `feat(security): add LLM client and scanner orchestrator`
7. `feat(security): add HTTP handlers and main server`
8. `feat(security): add OPA policies for all supported tools`
9. `feat(backend): add security agent proxy handler`
10. `feat(frontend): add security types and API functions`
11. `feat(frontend): add security scanner UI components`
12. `feat(frontend): wire Security Scanner into SRE sidebar and dashboard`
13. `feat(k8s): add security-agent deployment and update kubeui env`
14. `feat: add security agent Makefile targets and build script`
15. `feat: IaC Security Agent — complete implementation`
