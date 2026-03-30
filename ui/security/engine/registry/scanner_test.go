package registry_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	regscanner "kubeui/security/engine/registry"
)

func TestScanRegistryReturnsResources(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/v2/_catalog", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"repositories":["myimage"]}`))
	})
	mux.HandleFunc("/v2/myimage/tags/list", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"name":"myimage","tags":["latest","v1.0"]}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()

	resources, err := regscanner.Scan(srv.URL, true, "", "")
	if err != nil {
		t.Fatalf("Scan: %v", err)
	}
	if len(resources) != 2 {
		t.Fatalf("expected 2 resources (latest + v1.0), got %d", len(resources))
	}
	// latest tag should be flagged as mutable
	for _, r := range resources {
		if r.Attributes["tag"] == "latest" {
			if r.Attributes["is_mutable_tag"] != true {
				t.Errorf("expected is_mutable_tag=true for latest tag")
			}
		}
		if r.Tool != "registry" {
			t.Errorf("want tool=registry, got %s", r.Tool)
		}
	}
}
