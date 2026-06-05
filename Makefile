KIND_CLUSTER  ?= claude-obs
# pinned to live-synced version v3.4.3
ARGOCD_VERSION ?= v3.4.3

# This machine runs podman, not docker. kind talks to the running podman machine.
export KIND_EXPERIMENTAL_PROVIDER = podman

.PHONY: up down cluster argocd root status password help

help:
	@echo "make up        - create kind cluster, install Argo CD, apply root app"
	@echo "make down      - delete the kind cluster (PVC data is lost)"
	@echo "make status    - list Argo CD Applications"
	@echo "make password  - print the Argo CD admin password"

up: cluster argocd root
	@echo ""
	@echo "Bootstrapped. Argo CD is syncing the stack from the Git remote."
	@echo "Watch:    kubectl get applications -n argocd -w"
	@echo "Grafana:  http://localhost:3000  (admin / admin)"

cluster:
	kind create cluster --config kind/cluster.yaml

argocd:
	kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
	# server-side apply: Argo's CRDs exceed kubectl's client-side annotation limit
	kubectl apply --server-side --force-conflicts -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/$(ARGOCD_VERSION)/manifests/install.yaml
	kubectl rollout status -n argocd deploy/argocd-server --timeout=300s

root:
	kubectl apply -f bootstrap/argocd/root-app.yaml

down:
	kind delete cluster --name $(KIND_CLUSTER)

status:
	kubectl get applications -n argocd

password:
	@kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
