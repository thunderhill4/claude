package main

import (
	"log"
	"net/http"
	"os"

	"kubeui/security/engine"
	"kubeui/security/handlers"
	"kubeui/security/llm"
	"kubeui/security/opa"
)

func main() {
	policiesDir := os.Getenv("OPA_POLICIES_DIR")
	if policiesDir == "" {
		policiesDir = "./opa/policies"
	}

	evaluator, err := opa.NewEvaluator(policiesDir)
	if err != nil {
		log.Fatalf("failed to load OPA policies: %v", err)
	}
	log.Printf("loaded %d OPA policies from %s", len(evaluator.LoadedPolicies()), policiesDir)

	var llmClient *llm.Client
	if ollamaURL := os.Getenv("OLLAMA_URL"); ollamaURL != "" {
		model := os.Getenv("OLLAMA_MODEL")
		if model == "" {
			model = "llama3"
		}
		llmClient = llm.NewClient(ollamaURL, model)
		log.Printf("LLM client configured: %s model=%s", ollamaURL, model)
	}

	scanner := engine.NewScanner(evaluator, llmClient)
	h := handlers.New(scanner, evaluator, llmClient)

	addr := os.Getenv("LISTEN_ADDR")
	if addr == "" {
		addr = ":8082"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/scan", h.HandleScan)
	mux.HandleFunc("/scan/registry", h.HandleRegistryScan)
	mux.HandleFunc("/rules", h.HandleRules)
	mux.HandleFunc("/healthz", h.HandleHealthz)

	// CORS middleware
	corsHandler := corsMiddleware(mux)

	log.Printf("security agent listening on %s", addr)
	if err := http.ListenAndServe(addr, corsHandler); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func corsMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		origin := r.Header.Get("Origin")
		allowed := map[string]bool{
			"http://localhost:5173":  true,
			"http://127.0.0.1:5173": true,
			"http://172.18.255.211": true,
		}
		if allowed[origin] {
			w.Header().Set("Access-Control-Allow-Origin", origin)
		}
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}
