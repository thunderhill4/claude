package handlers

import (
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"strings"
)

// SecurityProxy proxies /api/v1/security/* → security agent
type SecurityProxy struct {
	proxy   *httputil.ReverseProxy
	baseURL string
}

func NewSecurityProxy() *SecurityProxy {
	baseURL := os.Getenv("SECURITY_AGENT_URL")
	if baseURL == "" {
		baseURL = "http://security-agent.kubeui.svc.cluster.local:8082"
	}

	target, err := url.Parse(baseURL)
	if err != nil {
		log.Fatalf("invalid SECURITY_AGENT_URL: %v", err)
	}

	proxy := httputil.NewSingleHostReverseProxy(target)

	// Strip the /api/v1/security prefix before forwarding
	originalDirector := proxy.Director
	proxy.Director = func(req *http.Request) {
		originalDirector(req)
		req.URL.Path = strings.TrimPrefix(req.URL.Path, "/api/v1/security")
		if req.URL.Path == "" {
			req.URL.Path = "/"
		}
		req.URL.RawPath = ""
	}

	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		log.Printf("security proxy error: %v", err)
		http.Error(w, "security agent unavailable", http.StatusBadGateway)
	}

	return &SecurityProxy{proxy: proxy, baseURL: baseURL}
}

func (s *SecurityProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.proxy.ServeHTTP(w, r)
}
