package opa_test

import (
	"context"
	"testing"

	"kubeui/security/model"
	secopa "kubeui/security/opa"
)

func TestEvaluatorFindsUnrestrictedIngress(t *testing.T) {
	eval, err := secopa.NewEvaluator("policies")
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
	eval, err := secopa.NewEvaluator("policies")
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
		t.Errorf("expected no findings, got %d", len(findings))
	}
}
