package main

import (
	"log"
	"net/http"
	"strings"

	"kubeui/backend/handlers"
	k8sclient "kubeui/backend/k8s"
)

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowedOrigins := []string{
			"http://localhost:5173",
			"http://127.0.0.1:5173",
		}

		for _, allowed := range allowedOrigins {
			if origin == allowed {
				w.Header().Set("Access-Control-Allow-Origin", origin)
				break
			}
		}

		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, PUT, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization")
		w.Header().Set("Access-Control-Allow-Credentials", "true")

		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusOK)
			return
		}

		next.ServeHTTP(w, r)
	})
}

func main() {
	// Initialize Kubernetes client
	if err := k8sclient.Init(); err != nil {
		log.Printf("WARNING: Failed to initialize Kubernetes client: %v", err)
		log.Println("The server will start but cluster endpoints will return empty results.")
	} else {
		log.Println("Kubernetes client initialized successfully")
	}

	mux := http.NewServeMux()

	// Cluster status (management cluster)
	mux.HandleFunc("/api/v1/cluster/status", handlers.HandleClusterStatus)

	// Target cluster deployment / deletion
	mux.HandleFunc("/api/v1/cluster/deploy", handlers.HandleDeployCluster)
	mux.HandleFunc("/api/v1/cluster/deploy/logs", handlers.HandleDeployLogs)
	mux.HandleFunc("/api/v1/cluster/delete", handlers.HandleDeleteClusterStream)
	mux.HandleFunc("/api/v1/cluster/target-status", handlers.HandleTargetClusterStatus)
	mux.HandleFunc("/api/v1/cluster/target-delete", handlers.HandleDeleteCluster)

	// CDI image repository
	mux.HandleFunc("/api/v1/images", handlers.HandleCDIImages)

	// Container registry
	mux.HandleFunc("/api/v1/registry/images", handlers.HandleRegistryImages)
	mux.HandleFunc("/api/v1/registry/images/", handlers.HandleRegistryDeleteImage)
	mux.HandleFunc("/api/v1/registry/config", handlers.HandleRegistryConfig)

	// Resources
	mux.HandleFunc("/api/v1/nodes", handlers.HandleNodes)
	mux.HandleFunc("/api/v1/pods", handlers.HandlePods)
	mux.HandleFunc("/api/v1/namespaces", handlers.HandleNamespaces)
	mux.HandleFunc("/api/v1/events", handlers.HandleEvents)

	// Virtual Machines - use a single handler that dispatches based on path
	mux.HandleFunc("/api/v1/virtualmachines", handlers.HandleVirtualMachines)
	mux.HandleFunc("/api/v1/virtualmachines/", func(w http.ResponseWriter, r *http.Request) {
		// Route /api/v1/virtualmachines/{namespace}/{name} to single VM handler
		path := strings.TrimPrefix(r.URL.Path, "/api/v1/virtualmachines/")
		if path != "" && strings.Contains(path, "/") {
			handlers.HandleVirtualMachine(w, r)
		} else {
			handlers.HandleVirtualMachines(w, r)
		}
	})

	// AI Chat & Agents
	mux.HandleFunc("/api/ai/chat", handlers.HandleAIChat)
	mux.HandleFunc("/api/ai/agents", handlers.HandleListAgents)

	// Health check
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	server := &http.Server{
		Addr:    ":8080",
		Handler: corsMiddleware(mux),
	}

	log.Println("Backend server starting on :8080")
	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
