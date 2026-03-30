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
