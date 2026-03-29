package model_test

import (
	"encoding/json"
	"testing"
	"time"

	"kubeui/security/model"
)

func TestScanResultJSON(t *testing.T) {
	result := model.ScanResult{
		Tool:       "terraform",
		Filename:   "main.tf",
		Findings:   []model.Finding{},
		ScannedAt:  time.Now(),
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
	if out.Filename != "main.tf" {
		t.Errorf("Filename: want main.tf, got %s", out.Filename)
	}
	if out.DurationMs != 42 {
		t.Errorf("DurationMs: want 42, got %d", out.DurationMs)
	}
}

func TestFindingJSON(t *testing.T) {
	f := model.Finding{
		ID:          "TF-NET-001",
		Severity:    "critical",
		Category:    "network",
		Resource:    "aws_security_group.web",
		Title:       "Unrestricted ingress",
		Description: "...",
		Remediation: "Restrict CIDR",
		Confidence:  0.95,
	}
	b, err := json.Marshal(f)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var out model.Finding
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if out.ID != f.ID {
		t.Errorf("ID: want %q, got %q", f.ID, out.ID)
	}
	if out.Severity != f.Severity {
		t.Errorf("Severity: want %q, got %q", f.Severity, out.Severity)
	}
	if out.Confidence != f.Confidence {
		t.Errorf("Confidence: want %f, got %f", f.Confidence, out.Confidence)
	}
}
