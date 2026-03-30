package terraform

import (
	"fmt"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/hclsyntax"
	"github.com/zclconf/go-cty/cty"
	"kubeui/security/model"
)

// Parse parses HCL terraform content and returns a slice of Resources.
func Parse(filename string, content []byte) ([]model.Resource, error) {
	file, diags := hclsyntax.ParseConfig(content, filename, hcl.Pos{Line: 1, Column: 1})
	if diags.HasErrors() {
		return nil, fmt.Errorf("HCL parse error: %s", diags.Error())
	}

	body, ok := file.Body.(*hclsyntax.Body)
	if !ok {
		return nil, fmt.Errorf("unexpected body type")
	}

	var resources []model.Resource
	for _, block := range body.Blocks {
		if block.Type != "resource" || len(block.Labels) < 2 {
			continue
		}
		r := model.Resource{
			Tool:       "terraform",
			Type:       block.Labels[0],
			Name:       block.Labels[1],
			Attributes: extractAttributes(block.Body),
			Location: model.Location{
				Line:   block.OpenBraceRange.Start.Line,
				Column: block.OpenBraceRange.Start.Column,
			},
		}
		resources = append(resources, r)
	}
	return resources, nil
}

func extractAttributes(body *hclsyntax.Body) map[string]any {
	attrs := make(map[string]any)

	for name, attr := range body.Attributes {
		val, diags := attr.Expr.Value(nil)
		if diags.HasErrors() {
			continue
		}
		attrs[name] = ctyToGo(val)
	}

	blockGroups := make(map[string][]any)
	for _, block := range body.Blocks {
		nested := extractAttributes(block.Body)
		blockGroups[block.Type] = append(blockGroups[block.Type], nested)
	}
	for k, v := range blockGroups {
		attrs[k] = v
	}
	return attrs
}

func ctyToGo(val cty.Value) any {
	if val.IsNull() || !val.IsKnown() {
		return nil
	}
	t := val.Type()
	switch {
	case t == cty.String:
		return val.AsString()
	case t == cty.Number:
		f, _ := val.AsBigFloat().Float64()
		return f
	case t == cty.Bool:
		return val.True()
	case t.IsListType() || t.IsTupleType() || t.IsSetType():
		var items []any
		for it := val.ElementIterator(); it.Next(); {
			_, v := it.Element()
			items = append(items, ctyToGo(v))
		}
		return items
	case t.IsObjectType() || t.IsMapType():
		m := make(map[string]any)
		for it := val.ElementIterator(); it.Next(); {
			k, v := it.Element()
			m[k.AsString()] = ctyToGo(v)
		}
		return m
	default:
		return fmt.Sprintf("%v", val)
	}
}
