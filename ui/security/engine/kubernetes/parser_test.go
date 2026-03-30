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

const multiDocYAML = `
apiVersion: v1
kind: Pod
metadata:
  name: pod1
  namespace: default
spec: {}
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: config1
  namespace: default
data:
  key: value
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
	if r.Namespace != "default" {
		t.Errorf("want namespace=default, got %s", r.Namespace)
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

func TestParseMultiDoc(t *testing.T) {
	resources, err := k8sparser.Parse([]byte(multiDocYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(resources) != 2 {
		t.Fatalf("expected 2 resources, got %d", len(resources))
	}
	types := map[string]bool{resources[0].Type: true, resources[1].Type: true}
	if !types["Pod"] || !types["ConfigMap"] {
		t.Errorf("expected Pod and ConfigMap, got %v and %v", resources[0].Type, resources[1].Type)
	}
}
