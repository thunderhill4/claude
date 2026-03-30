package kubevirt

import (
	"bytes"
	"fmt"
	"io"

	"gopkg.in/yaml.v3"
	"kubeui/security/model"
)

// Parse parses VirtualMachine/VMITemplate YAML into Resources.
func Parse(content []byte) ([]model.Resource, error) {
	var resources []model.Resource
	dec := yaml.NewDecoder(bytes.NewReader(content))
	for {
		var raw map[string]any
		if err := dec.Decode(&raw); err != nil {
			if err == io.EOF {
				break
			}
			return resources, fmt.Errorf("yaml decode: %w", err)
		}
		if raw == nil {
			continue
		}
		kind, _ := raw["kind"].(string)
		if kind == "" {
			continue
		}
		meta, _ := raw["metadata"].(map[string]any)
		name, _ := meta["name"].(string)
		ns, _ := meta["namespace"].(string)
		resources = append(resources, model.Resource{
			Tool:       "kubevirt",
			Type:       kind,
			Name:       name,
			Namespace:  ns,
			Attributes: raw,
		})
	}
	return resources, nil
}
