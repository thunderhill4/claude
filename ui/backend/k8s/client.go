package k8s

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

var (
	Clientset     kubernetes.Interface
	DynamicClient dynamic.Interface
)

func Init() error {
	config, err := getConfig()
	if err != nil {
		return fmt.Errorf("failed to get kubernetes config: %w", err)
	}

	Clientset, err = kubernetes.NewForConfig(config)
	if err != nil {
		return fmt.Errorf("failed to create kubernetes clientset: %w", err)
	}

	DynamicClient, err = dynamic.NewForConfig(config)
	if err != nil {
		return fmt.Errorf("failed to create dynamic client: %w", err)
	}

	return nil
}

func getConfig() (*rest.Config, error) {
	// 1. Check KUBECONFIG env var
	kubeconfig := os.Getenv("KUBECONFIG")
	if kubeconfig != "" {
		config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err == nil {
			return config, nil
		}
	}

	// 2. Fallback to ~/.kube/config
	home, err := os.UserHomeDir()
	if err == nil {
		defaultPath := filepath.Join(home, ".kube", "config")
		if _, err := os.Stat(defaultPath); err == nil {
			config, err := clientcmd.BuildConfigFromFlags("", defaultPath)
			if err == nil {
				return config, nil
			}
		}
	}

	// 3. Fallback to in-cluster config
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, fmt.Errorf("no valid kubeconfig found: %w", err)
	}
	return config, nil
}

// ─── Per-context clients (multi-cluster reads) ──────────────────────────────
//
// The package-level Clientset/DynamicClient above are bound to whichever
// context the backend booted with — in practice cluster2. The Istio demo in
// 07-istio-advanced/ lives mostly on cluster1, which the backend has no
// dedicated config for, so reads need a client per named kubeconfig context.
//
// This is deliberately ALLOWED TO FAIL. When the backend runs in-cluster there
// is no kubeconfig with a cluster1 context at all, and that is not an error
// worth 500ing over — handlers degrade to partial data and report it via their
// `source` field, matching the skeleton+overlay approach in handlers/mesh.go.

// ClusterClients bundles the typed and dynamic clients for one cluster.
type ClusterClients struct {
	Clientset kubernetes.Interface
	Dynamic   dynamic.Interface
	Context   string
}

var (
	ctxClientsMu sync.Mutex
	ctxClients   = map[string]*ClusterClients{}
	ctxErrs      = map[string]error{}
)

// ForContext returns cached clients for a named kubeconfig context
// (e.g. "kind-cluster1"). Failures are cached too, so an unreachable context
// costs one attempt rather than one per request.
func ForContext(name string) (*ClusterClients, error) {
	ctxClientsMu.Lock()
	defer ctxClientsMu.Unlock()

	if c, ok := ctxClients[name]; ok {
		return c, nil
	}
	if err, ok := ctxErrs[name]; ok {
		return nil, err
	}

	c, err := buildForContext(name)
	if err != nil {
		ctxErrs[name] = err
		return nil, err
	}
	ctxClients[name] = c
	return c, nil
}

// ResetContextCache clears the memoized clients and errors. Useful after a
// kubeconfig change so a previously unreachable context can be retried.
func ResetContextCache() {
	ctxClientsMu.Lock()
	defer ctxClientsMu.Unlock()
	ctxClients = map[string]*ClusterClients{}
	ctxErrs = map[string]error{}
}

func buildForContext(name string) (*ClusterClients, error) {
	rules := clientcmd.NewDefaultClientConfigLoadingRules()
	cfg, err := clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		rules,
		&clientcmd.ConfigOverrides{CurrentContext: name},
	).ClientConfig()
	if err != nil {
		return nil, fmt.Errorf("context %q unavailable: %w", name, err)
	}
	// Keep this short: these calls sit behind interactive dashboard requests,
	// and an unreachable cluster must not hold the whole page hostage.
	cfg.Timeout = 6 * time.Second

	cs, err := kubernetes.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("context %q clientset: %w", name, err)
	}
	dyn, err := dynamic.NewForConfig(cfg)
	if err != nil {
		return nil, fmt.Errorf("context %q dynamic client: %w", name, err)
	}
	return &ClusterClients{Clientset: cs, Dynamic: dyn, Context: name}, nil
}
