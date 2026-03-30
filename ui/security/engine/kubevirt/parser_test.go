package kubevirt_test

import (
	"testing"

	kvparser "kubeui/security/engine/kubevirt"
)

const vmYAML = `
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: test-vm
  namespace: default
spec:
  template:
    spec:
      domain:
        resources: {}
`

const multiVMYAML = `
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: vm1
  namespace: default
spec: {}
---
apiVersion: kubevirt.io/v1
kind: VirtualMachineInstanceTemplate
metadata:
  name: vmit1
  namespace: default
spec: {}
`

func TestParseVM(t *testing.T) {
	resources, err := kvparser.Parse([]byte(vmYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(resources) == 0 {
		t.Fatal("expected at least one resource")
	}
	r := resources[0]
	if r.Type != "VirtualMachine" {
		t.Errorf("want VirtualMachine, got %s", r.Type)
	}
	if r.Name != "test-vm" {
		t.Errorf("want test-vm, got %s", r.Name)
	}
	if r.Tool != "kubevirt" {
		t.Errorf("want kubevirt, got %s", r.Tool)
	}
	if r.Namespace != "default" {
		t.Errorf("want namespace=default, got %s", r.Namespace)
	}
}

func TestParseMultiVM(t *testing.T) {
	resources, err := kvparser.Parse([]byte(multiVMYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(resources) != 2 {
		t.Fatalf("expected 2 resources, got %d", len(resources))
	}
	types := map[string]bool{resources[0].Type: true, resources[1].Type: true}
	if !types["VirtualMachine"] || !types["VirtualMachineInstanceTemplate"] {
		t.Errorf("unexpected types: %v, %v", resources[0].Type, resources[1].Type)
	}
}
