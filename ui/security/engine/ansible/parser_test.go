package ansible_test

import (
	"testing"

	ansibleparser "kubeui/security/engine/ansible"
)

const playbookYAML = `
- name: Configure web server
  hosts: webservers
  tasks:
    - name: Install nginx
      apt:
        name: nginx
        state: present
    - name: Start service
      become: true
      service:
        name: nginx
        state: started
`

func TestParsePlaybook(t *testing.T) {
	resources, err := ansibleparser.Parse([]byte(playbookYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if len(resources) != 2 {
		t.Fatalf("expected 2 task resources, got %d", len(resources))
	}
	for _, r := range resources {
		if r.Tool != "ansible" {
			t.Errorf("want tool=ansible, got %s", r.Tool)
		}
		if r.Type != "task" {
			t.Errorf("want type=task, got %s", r.Type)
		}
	}
	// First task name
	if resources[0].Name != "Install nginx" {
		t.Errorf("want 'Install nginx', got %q", resources[0].Name)
	}
}

func TestParseTaskWithBecome(t *testing.T) {
	resources, err := ansibleparser.Parse([]byte(playbookYAML))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	// Second task has become: true
	found := false
	for _, r := range resources {
		if become, ok := r.Attributes["become"].(bool); ok && become {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected a task with become=true in attributes")
	}
}
