.PHONY: all prereqs metallb capi-init target-cluster target-cluster-lite target-cluster-full verify clean ui ui-build registry bake-image demo help pre-pull istio security-agent security-agent-build security-policies security-deploy

REGISTRY_URL := 172.18.0.2:5000
CONTAINER_IMAGE := $(REGISTRY_URL)/ubuntu-noble-k3s:latest
KIND_NODES := $(shell docker ps --filter "name=cluster2" --format '{{.Names}}')

all: prereqs metallb capi-init target-cluster

help:
	@echo "KubeVirt Cluster API Demo"
	@echo ""
	@echo "Cluster Lifecycle:"
	@echo "  make all                  - Full setup (prereqs + metallb + capi + cluster)"
	@echo "  make target-cluster       - Deploy target cluster (full profile)"
	@echo "  make target-cluster-lite  - Deploy target cluster (lite: 2 CPU · 4Gi)"
	@echo "  make target-cluster-full  - Deploy target cluster (full: 4 CPU · 8/6Gi)"
	@echo "  make verify               - Verify the target cluster"
	@echo "  make istio                - Install Istio ambient + nginx sample on target cluster"
	@echo "  make clean                - Delete the target cluster"
	@echo "  make demo                 - Run interactive demo script"
	@echo ""
	@echo "Prerequisites:"
	@echo "  make prereqs        - Install clusterctl"
	@echo "  make metallb        - Install MetalLB"
	@echo "  make capi-init      - Initialize CAPI providers"
	@echo ""
	@echo "Golden Image:"
	@echo "  make bake-image     - Bake Ubuntu k3s golden image"
	@echo "  make registry       - List images in local registry"
	@echo "  make pre-pull       - Pre-pull VM image on Kind nodes (faster deploys)"
	@echo ""
	@echo "Web UI:"
	@echo "  make ui             - Run the web UI (frontend + backend)"
	@echo "  make ui-build       - Build the UI for production"
	@echo ""
	@echo "Security Agent:"
	@echo "  make security-agent       - Run security agent in development mode (port 8082)"
	@echo "  make security-agent-build - Build security agent binary"
	@echo "  make security-policies    - Regenerate OPA policies ConfigMap in kubeui namespace"
	@echo "  make security-deploy      - Build and deploy security agent to cluster2"
	@echo ""

prereqs:
	bash 00-prereqs/install-clusterctl.sh

metallb:
	bash 01-metallb/install-metallb.sh

capi-init:
	bash 02-capi-init/init-management-cluster.sh

target-cluster: target-cluster-full

target-cluster-lite:
	kubectl apply -f 03-target-cluster/target-cluster-lite.yaml

target-cluster-full:
	kubectl apply -f 03-target-cluster/target-cluster.yaml

verify:
	bash 04-verify/verify-cluster.sh

istio:
	bash 05-istio/install-istio-ambient.sh /tmp/target-cluster-kubeconfig

clean:
	kubectl delete cluster target-cluster --ignore-not-found
	@echo "Cluster deletion initiated. VMs and resources will be cleaned up by CAPI controllers."

demo:
	./demo.sh

# ── Golden Image ──────────────────────────────────────────────

bake-image:
	./bake-golden-image.sh

registry:
	@echo "Container Registry: http://$(REGISTRY_URL)"
	@echo ""
	@echo "Images:"
	@curl -s http://$(REGISTRY_URL)/v2/_catalog | jq -r '.repositories[]' 2>/dev/null || echo "  (registry not accessible)"
	@echo ""
	@echo "Tags for ubuntu-noble-k3s:"
	@curl -s http://$(REGISTRY_URL)/v2/ubuntu-noble-k3s/tags/list | jq -r '.tags[]' 2>/dev/null || echo "  (image not found)"

pre-pull:
	@echo "Pre-pulling $(CONTAINER_IMAGE) on Kind nodes..."
	@for node in $(KIND_NODES); do \
		echo "  Pulling on $$node..."; \
		docker exec $$node crictl pull $(CONTAINER_IMAGE) 2>/dev/null || \
		docker exec $$node ctr -n k8s.io images pull --plain-http $(CONTAINER_IMAGE) 2>/dev/null || \
		echo "    (pull command not available on $$node)"; \
	done
	@echo "Done."

# ── Web UI ────────────────────────────────────────────────────

ui:
	./run-ui.sh

ui-build:
	cd ui/frontend && npm install && npm run build
	cd ui/backend && go build -o ../dist/backend .
	@echo "UI built to ui/dist/"

# ── Security Agent ────────────────────────────────────────────

security-agent: ## Run security agent in development mode (port 8082)
	cd ui/security && OPA_POLICIES_DIR=./opa/policies go run .

security-agent-build: ## Build security agent binary
	cd ui/security && CGO_ENABLED=0 GOOS=linux go build -o ../../bin/security-agent .

security-policies: ## Regenerate OPA policies ConfigMap in kubeui namespace
	kubectl create configmap opa-policies \
		--from-file=ui/security/opa/policies/ \
		-n kubeui --dry-run=client -o yaml | \
		kubectl apply -f -

security-deploy: ## Build and deploy security agent to cluster2
	bash ui/k8s/build-and-deploy-security.sh
