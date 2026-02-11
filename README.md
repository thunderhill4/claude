# CAPI-on-KubeVirt Management Cluster

Provisions a target Kubernetes cluster (k3s) where nodes run as KubeVirt VMs inside a Kind management cluster.

## Prerequisites

- Kind cluster running with KubeVirt + CDI installed
- `ubuntu-noble-dv` DataVolume available in default namespace
- Docker, kubectl on the host

## Quick Start

```bash
# Run all steps sequentially
make all

# Or run each step individually:
make prereqs       # Install clusterctl
make metallb       # Install MetalLB with auto-detected IP range
make capi-init     # Initialize CAPI with CAPK + k3s providers
make target-cluster # Deploy the target cluster

# Verify (run after VMs are up, ~5-10 min)
make verify
```

## Architecture

- **Management Cluster**: Kind cluster with CAPI, CAPK, k3s providers, MetalLB
- **Target Cluster**: 1 control plane VM + 1 worker VM running k3s
- **Networking**: KubeVirt masquerade (pod network), MetalLB L2 for LoadBalancer
- **Storage**: DataVolume clones from `ubuntu-noble-dv`

## Cleanup

```bash
make clean
```
