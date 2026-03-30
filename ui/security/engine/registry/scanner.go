package registry

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"kubeui/security/model"
)

// Scan enumerates images in a Docker v2 registry and returns Resources.
func Scan(registryURL string, insecure bool, username, password string) ([]model.Resource, error) {
	base := strings.TrimRight(registryURL, "/")
	if !strings.HasPrefix(base, "http") {
		scheme := "https"
		if insecure {
			scheme = "http"
		}
		base = scheme + "://" + base
	}

	client := &http.Client{Timeout: 30 * time.Second}

	repos, err := getJSON[struct {
		Repositories []string `json:"repositories"`
	}](client, base+"/v2/_catalog", username, password)
	if err != nil {
		return nil, fmt.Errorf("listing catalog: %w", err)
	}

	var resources []model.Resource
	for _, repo := range repos.Repositories {
		tags, err := getJSON[struct {
			Tags []string `json:"tags"`
		}](client, fmt.Sprintf("%s/v2/%s/tags/list", base, repo), username, password)
		if err != nil {
			continue
		}

		for _, tag := range tags.Tags {
			attrs := map[string]any{
				"repository":     repo,
				"tag":            tag,
				"registry":       base,
				"is_mutable_tag": tag == "latest",
			}
			resources = append(resources, model.Resource{
				Tool:       "registry",
				Type:       "image",
				Name:       fmt.Sprintf("%s:%s", repo, tag),
				Attributes: attrs,
			})
		}
	}
	return resources, nil
}

func getJSON[T any](client *http.Client, url, user, pass string) (T, error) {
	var zero T
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return zero, err
	}
	if user != "" {
		req.SetBasicAuth(user, pass)
	}
	resp, err := client.Do(req)
	if err != nil {
		return zero, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return zero, err
	}
	var result T
	return result, json.Unmarshal(b, &result)
}
