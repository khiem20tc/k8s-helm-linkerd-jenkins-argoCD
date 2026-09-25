# Local lab: kind + registry + ingress-nginx + Linkerd + Argo CD + Jenkins.
#
# Everything runs against the isolated kubeconfig in on-prem/.kube/config and the
# kind-$(CLUSTER_NAME) context. The default ~/.kube/config is never used.

SHELL := /bin/bash
SCRIPTS := ./scripts
ONPREM_DIR := $(CURDIR)

include config.env
-include .env

export KUBECONFIG := $(ONPREM_DIR)/.kube/config
export PATH := $(ONPREM_DIR)/.bin:$(PATH)
KUBE_CONTEXT := kind-$(CLUSTER_NAME)

.DEFAULT_GOAL := help
.PHONY: help up start stop down destroy tools cluster ingress metrics-server linkerd linkerd-viz argocd jenkins \
	monitoring apps image status urls linkerd-dashboard kubectl-env

help: ## Show this help message
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

up: tools cluster image ## Create the whole lab (cluster, registry, addons, apps)
	$(SCRIPTS)/addons.sh all
	@$(SCRIPTS)/info.sh urls

start: ## Resume a stopped lab
	$(SCRIPTS)/cluster.sh start

stop: ## Pause the lab (frees CPU/RAM, keeps all state)
	$(SCRIPTS)/cluster.sh stop

down: ## Delete the kind cluster (keeps the registry and its images)
	$(SCRIPTS)/cluster.sh delete

destroy: ## Delete the kind cluster and the local registry
	$(SCRIPTS)/cluster.sh delete --registry

tools: ## Download pinned CLIs (kind, helm, linkerd) into on-prem/.bin
	$(SCRIPTS)/tools.sh

cluster: ## Create the kind cluster and local registry
	$(SCRIPTS)/cluster.sh create

ingress: ## Install ingress-nginx
	$(SCRIPTS)/addons.sh ingress

metrics-server: ## Install metrics-server (needed by the HPA)
	$(SCRIPTS)/addons.sh metrics-server

linkerd: ## Install Gateway API CRDs and Linkerd
	$(SCRIPTS)/addons.sh linkerd

linkerd-viz: ## Install the Linkerd viz extension
	$(SCRIPTS)/addons.sh linkerd-viz

argocd: ## Install Argo CD
	$(SCRIPTS)/addons.sh argocd

jenkins: ## Install Jenkins (preconfigured job, credentials, local registry)
	$(SCRIPTS)/addons.sh jenkins

monitoring: ## Install kube-prometheus-stack (heavy, optional)
	$(SCRIPTS)/addons.sh monitoring

apps: ## Create the Argo CD applications for ENVIRONMENTS
	$(SCRIPTS)/addons.sh apps

image: ## Build and push user-service to the local registry (TAG=latest)
	$(SCRIPTS)/image.sh $(or $(TAG),latest)

status: ## Show nodes, Argo CD apps and workloads
	@$(SCRIPTS)/info.sh status

urls: ## Show URLs and credentials
	@$(SCRIPTS)/info.sh urls

linkerd-dashboard: ## Open the Linkerd viz dashboard
	linkerd --kubeconfig $(KUBECONFIG) --context $(KUBE_CONTEXT) viz dashboard

kubectl-env: ## Print the export line to use kubectl against the lab
	@echo "export KUBECONFIG=$(KUBECONFIG)"
