package engine_test

import (
	"context"
	"testing"

	"kubeui/security/engine"
	"kubeui/security/model"
	"kubeui/security/opa"
)

const tfInsecureSG = `
resource "aws_security_group" "open" {
  name = "open"
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
`

func TestScanTerraformTFNET001(t *testing.T) {
	eval, err := opa.NewEvaluator("../opa/policies")
	if err != nil {
		t.Fatalf("NewEvaluator: %v", err)
	}

	scanner := engine.NewScanner(eval, nil)

	result, err := scanner.Scan(context.Background(), model.ScanRequest{
		Tool:     "terraform",
		Filename: "main.tf",
		Content:  tfInsecureSG,
	})
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}

	var found bool
	for _, f := range result.Findings {
		if f.ID == "TF-NET-001" {
			found = true
		}
	}
	if !found {
		t.Error("expected TF-NET-001 finding, got none")
		t.Logf("result: tool=%s filename=%s findings=%d", result.Tool, result.Filename, len(result.Findings))
		for _, f := range result.Findings {
			t.Logf("  finding: id=%s title=%s", f.ID, f.Title)
		}
	}
}
