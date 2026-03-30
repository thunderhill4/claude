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
	// Nested blocks are always stored as []any to support policies that iterate over them.
	ingressList, ok := r.Attributes["ingress"].([]any)
	if !ok {
		t.Fatalf("ingress should be []any, got %T", r.Attributes["ingress"])
	}
	if len(ingressList) == 0 {
		t.Fatal("ingress list should have at least one element")
	}
	ingress, ok := ingressList[0].(map[string]any)
	if !ok {
		t.Fatalf("ingress[0] should be map[string]any, got %T", ingressList[0])
	}
	cidrBlocks, ok := ingress["cidr_blocks"].([]any)
	if !ok {
		t.Fatalf("cidr_blocks should be []any, got %T: %v", ingress["cidr_blocks"], ingress["cidr_blocks"])
	}
	if len(cidrBlocks) == 0 || cidrBlocks[0] != "0.0.0.0/0" {
		t.Errorf("want cidr_blocks[0]=0.0.0.0/0, got %v", cidrBlocks)
	}
	fromPort, ok := ingress["from_port"].(float64)
	if !ok {
		t.Fatalf("from_port should be float64, got %T", ingress["from_port"])
	}
	if fromPort != 0 {
		t.Errorf("want from_port=0, got %v", fromPort)
	}
}
