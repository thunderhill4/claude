package handlers

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
)

type RegistryImage struct {
	Name    string    `json:"name"`
	Tags    []string  `json:"tags"`
	TagInfo []TagInfo `json:"tagInfo"`
}

type TagInfo struct {
	Tag     string `json:"tag"`
	Digest  string `json:"digest"`
	Created string `json:"created"`
	Size    int64  `json:"size"`
}

type RegistryConfig struct {
	URL  string `json:"url"`
	Name string `json:"name"`
}

// registryURL is where this process actually DIALS the registry.
// registryAlias is the name shown in the UI and used in image references.
//
// These are deliberately separate. 172.18.0.2:5000 is a fixed ALIAS, not a real
// address: docker hands 172.18.0.2 to whichever container attached to the kind
// network first (usually a kind node), and the registry container's own IP
// drifts. Image pulls work because scripts/fix-registry-hosts.sh writes
// /etc/containerd/certs.d/<alias>/hosts.toml on each node, mapping the alias to
// the registry's current IP -- but that mapping is containerd-only. A plain Go
// HTTP client gets connection refused, which is why the Registry tab reported
// "disconnected" from both the host and in-cluster.
//
// So: dial a real address via REGISTRY_URL, keep displaying the alias.
//
//	dev (run-ui.sh, host process): http://localhost:5000  (published port)
//	in-cluster:                    the registry's kind-network IP:5000
var (
	registryURL   = envOrDefault("REGISTRY_URL", "http://172.18.0.2:5000")
	registryAlias = envOrDefault("REGISTRY_ALIAS", "172.18.0.2:5000")
)

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// GET /api/v1/registry/images
func HandleRegistryImages(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	client := &http.Client{Timeout: 10 * time.Second}

	// Get catalog (list of repositories)
	catalogURL := fmt.Sprintf("%s/v2/_catalog", registryURL)
	resp, err := client.Get(catalogURL)
	if err != nil {
		log.Printf("Error fetching registry catalog: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to connect to registry")
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		log.Printf("Registry returned status %d", resp.StatusCode)
		writeError(w, http.StatusInternalServerError, "registry unavailable")
		return
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		log.Printf("Error reading registry response: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to read response")
		return
	}

	var catalog struct {
		Repositories []string `json:"repositories"`
	}
	if err := json.Unmarshal(body, &catalog); err != nil {
		log.Printf("Error parsing catalog: %v", err)
		writeError(w, http.StatusInternalServerError, "failed to parse catalog")
		return
	}

	images := make([]RegistryImage, 0, len(catalog.Repositories))
	for _, repoName := range catalog.Repositories {
		img := RegistryImage{Name: repoName}

		// Get tags for this repository
		tagsURL := fmt.Sprintf("%s/v2/%s/tags/list", registryURL, repoName)
		tagsResp, err := client.Get(tagsURL)
		if err != nil {
			log.Printf("Error fetching tags for %s: %v", repoName, err)
			images = append(images, img)
			continue
		}

		tagsBody, _ := io.ReadAll(tagsResp.Body)
		tagsResp.Body.Close()

		var tagsData struct {
			Name string   `json:"name"`
			Tags []string `json:"tags"`
		}
		if err := json.Unmarshal(tagsBody, &tagsData); err == nil {
			img.Tags = tagsData.Tags

			// Get manifest info for each tag
			for _, tag := range img.Tags {
				tagInfo := TagInfo{Tag: tag}

				// Get manifest to retrieve digest
				manifestURL := fmt.Sprintf("%s/v2/%s/manifests/%s", registryURL, repoName, tag)
				req, _ := http.NewRequest("GET", manifestURL, nil)
				req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json")

				manifestResp, err := client.Do(req)
				if err == nil {
					tagInfo.Digest = manifestResp.Header.Get("Docker-Content-Digest")
					if tagInfo.Digest != "" && len(tagInfo.Digest) > 19 {
						tagInfo.Digest = tagInfo.Digest[:19] + "..."
					}
					manifestResp.Body.Close()
				}

				img.TagInfo = append(img.TagInfo, tagInfo)
			}
		}

		images = append(images, img)
	}

	writeJSON(w, images)
}

// GET /api/v1/registry/config
func HandleRegistryConfig(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// Check if registry is accessible
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Get(fmt.Sprintf("%s/v2/", registryURL))

	status := "connected"
	if err != nil || resp.StatusCode != http.StatusOK {
		status = "disconnected"
	}
	if resp != nil {
		resp.Body.Close()
	}

	// Show the alias, not the dial address: it is what image references use
	// (172.18.0.2:5000/ubuntu-noble-k3s:latest), so it is what a user needs to
	// see. Falls back to deriving from the URL if the alias is cleared.
	name := registryAlias
	if name == "" {
		name = strings.TrimPrefix(registryURL, "http://")
		name = strings.TrimPrefix(name, "https://")
	}

	config := map[string]string{
		"url":    registryURL,
		"name":   name,
		"status": status,
	}

	writeJSON(w, config)
}

// DELETE /api/v1/registry/images/{name}:{tag}
func HandleRegistryDeleteImage(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodDelete {
		writeError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}

	// Parse image name and tag from path
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/registry/images/")
	parts := strings.Split(path, ":")
	if len(parts) != 2 {
		writeError(w, http.StatusBadRequest, "invalid image reference, expected name:tag")
		return
	}

	imageName := parts[0]
	tag := parts[1]

	client := &http.Client{Timeout: 10 * time.Second}

	// First, get the manifest digest
	manifestURL := fmt.Sprintf("%s/v2/%s/manifests/%s", registryURL, imageName, tag)
	req, _ := http.NewRequest("GET", manifestURL, nil)
	req.Header.Set("Accept", "application/vnd.docker.distribution.manifest.v2+json")

	resp, err := client.Do(req)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to get manifest")
		return
	}
	digest := resp.Header.Get("Docker-Content-Digest")
	resp.Body.Close()

	if digest == "" {
		writeError(w, http.StatusNotFound, "image not found")
		return
	}

	// Delete by digest
	deleteURL := fmt.Sprintf("%s/v2/%s/manifests/%s", registryURL, imageName, digest)
	req, _ = http.NewRequest("DELETE", deleteURL, nil)

	resp, err = client.Do(req)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "failed to delete image")
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusAccepted && resp.StatusCode != http.StatusOK {
		writeError(w, http.StatusInternalServerError, fmt.Sprintf("delete failed with status %d", resp.StatusCode))
		return
	}

	writeJSON(w, map[string]string{"status": "deleted"})
}
