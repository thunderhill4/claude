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
