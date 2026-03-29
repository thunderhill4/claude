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
