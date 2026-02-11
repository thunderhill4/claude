.PHONY: all prereqs metallb capi-init target-cluster verify clean

all: prereqs metallb capi-init target-cluster

prereqs:
	bash 00-prereqs/install-clusterctl.sh

metallb:
	bash 01-metallb/install-metallb.sh

capi-init:
	bash 02-capi-init/init-management-cluster.sh

target-cluster:
	bash 03-target-cluster/generate-cluster.sh

verify:
	bash 04-verify/verify-cluster.sh

clean:
	kubectl delete cluster target-cluster --ignore-not-found
	@echo "Cluster deletion initiated. VMs and resources will be cleaned up by CAPI controllers."
