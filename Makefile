.DEFAULT_GOAL := help
SHELL := /bin/bash

PYTHON      ?= python3.11
VENV        ?= .venv
BIN         := $(VENV)/bin
MINIKUBE_PROFILE ?= recsys
NAMESPACE   ?= recsys

# =============================================================================
# Setup
# =============================================================================
.PHONY: venv
venv: ## Create the Python 3.11 virtualenv and install dev dependencies
	$(PYTHON) -m venv $(VENV)
	$(BIN)/pip install --upgrade pip
	$(BIN)/pip install -e ".[dev]"

.PHONY: check-env
check-env: ## Verify local tooling matches what the phases assume
	@bash scripts/check-env.sh

# =============================================================================
# Code quality  (Phase 13 wires these into CI)
# =============================================================================
.PHONY: lint
lint: ## ruff check + format check
	$(BIN)/ruff check .
	$(BIN)/ruff format --check .

.PHONY: format
format: ## Auto-fix lint and format
	$(BIN)/ruff check --fix .
	$(BIN)/ruff format .

.PHONY: typecheck
typecheck: ## mypy
	$(BIN)/mypy ml apps

.PHONY: test
test: ## Unit tests only (fast)
	$(BIN)/pytest -m unit

.PHONY: test-integration
test-integration: ## Integration tests (needs docker)
	$(BIN)/pytest -m integration

.PHONY: ci
ci: lint typecheck test ## Everything CI runs

# =============================================================================
# ML pipeline  (Phases 1-4)
# =============================================================================
.PHONY: generate-data
generate-data: ## Phase 1: generate the synthetic interaction dataset
	$(BIN)/python -m ml.data.generate

.PHONY: repro
repro: ## Phase 2: run the DVC pipeline (only stages whose inputs changed)
	$(BIN)/dvc repro

.PHONY: dvc-push
dvc-push: ## Phase 2: upload data/model artifacts to the S3 remote
	$(BIN)/dvc push

.PHONY: mlflow-ui
mlflow-ui: ## Phase 3: open the MLflow tracking UI against the local backend
	$(BIN)/mlflow ui --host 0.0.0.0 --port 5000

.PHONY: train
train: ## Phase 4: train the multi-task ranker (logs to MLflow)
	$(BIN)/python -m ml.training.train

.PHONY: evaluate
evaluate: ## Phase 4: evaluate vs. the popularity baseline
	$(BIN)/python -m ml.evaluation.evaluate

# =============================================================================
# Local Kubernetes  (Phases 6-12)
# =============================================================================
.PHONY: cluster-up
cluster-up: ## Phase 6: start the minikube profile sized for the full platform
	minikube start -p $(MINIKUBE_PROFILE) --cpus=6 --memory=11g --driver=docker

.PHONY: cluster-down
cluster-down: ## Stop the minikube profile (keeps state)
	minikube stop -p $(MINIKUBE_PROFILE)

.PHONY: install-kserve
install-kserve: ## Phase 6: install cert-manager + Istio + Knative + KServe (Serverless mode)
	bash scripts/install-kserve.sh

.PHONY: deploy
deploy: ## Phase 9: install/upgrade the platform Helm release
	helm upgrade --install recsys helm/recommendation-platform \
		--namespace $(NAMESPACE) --create-namespace \
		--values helm/recommendation-platform/values.yaml

.PHONY: undeploy
undeploy: ## Remove the Helm release
	helm uninstall recsys --namespace $(NAMESPACE)

# =============================================================================
# Utility
# =============================================================================
.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
