#!/usr/bin/env bash
# Verify local tooling matches what the build phases assume.
# Reports everything, then exits non-zero if a required tool is missing.
set -uo pipefail

PASS=0
FAIL=0
WARN=0

ok()   { printf '  \033[32m✓\033[0m %-14s %s\n' "$1" "$2"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %-14s %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33m!\033[0m %-14s %s\n' "$1" "$2"; WARN=$((WARN+1)); }

echo
echo "Environment check — recommendation-mlops"
echo "========================================"

# ---------------------------------------------------------------- required now
echo
echo "Required from Phase 1:"

if command -v python3.11 >/dev/null 2>&1; then
  ok "python3.11" "$(python3.11 --version 2>&1)"
elif python --version 2>&1 | grep -q '3\.11'; then
  ok "python 3.11" "$(python --version 2>&1)"
else
  bad "python3.11" "not found — see docs/adr/0002-pin-python-311.md for why 3.11 specifically"
fi

command -v git >/dev/null 2>&1 \
  && ok "git" "$(git --version)" \
  || bad "git" "not found"

# ---------------------------------------------------------------- Phase 2+
echo
echo "Required from Phase 2 (data versioning):"

if command -v aws >/dev/null 2>&1; then
  ok "aws cli" "$(aws --version 2>&1 | cut -d' ' -f1)"
  if aws sts get-caller-identity >/dev/null 2>&1; then
    ok "aws creds" "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)"
  else
    bad "aws creds" "configured CLI but 'sts get-caller-identity' failed — run 'aws configure'"
  fi
else
  bad "aws cli" "not found"
fi

# dvc lives in the project venv, not globally
if [ -x ".venv/bin/dvc" ]; then
  ok "dvc" "$(.venv/bin/dvc --version 2>&1) (venv)"
else
  warn "dvc" "not installed yet — 'make venv' installs it into .venv"
fi

# ---------------------------------------------------------------- Phase 6+
echo
echo "Required from Phase 6 (local Kubernetes):"

if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "docker" "$(docker --version | cut -d, -f1) — daemon running"
  else
    warn "docker" "installed but the daemon is not running — start Docker Desktop"
  fi
else
  bad "docker" "not found"
fi

command -v kubectl >/dev/null 2>&1 \
  && ok "kubectl" "$(kubectl version --client 2>/dev/null | awk '/Client Version/{print $3}')" \
  || bad "kubectl" "not found"

command -v helm >/dev/null 2>&1 \
  && ok "helm" "$(helm version --short 2>/dev/null)" \
  || bad "helm" "not found"

command -v minikube >/dev/null 2>&1 \
  && ok "minikube" "$(minikube version --short 2>/dev/null)" \
  || bad "minikube" "not found"

# The Serverless-mode stack (ADR-0001) plus the data services need real headroom.
if command -v free >/dev/null 2>&1; then
  TOTAL_GB=$(free -g | awk '/^Mem:/{print $2}')
  if [ "${TOTAL_GB:-0}" -ge 15 ]; then
    ok "memory" "${TOTAL_GB}GB total — minikube can take 11GB"
  else
    warn "memory" "${TOTAL_GB}GB total — the Phase 6 stack wants ~11GB for minikube"
  fi
fi

# ---------------------------------------------------------------- Phase 14
echo
echo "Required from Phase 14 (AWS):"

command -v terraform >/dev/null 2>&1 \
  && ok "terraform" "$(terraform version | head -1)" \
  || warn "terraform" "not found — only needed at Phase 14"

# ---------------------------------------------------------------- summary
echo
echo "----------------------------------------"
printf '  %d passed · %d warnings · %d failed\n' "$PASS" "$WARN" "$FAIL"
echo

if [ "$FAIL" -gt 0 ]; then
  echo "Missing required tooling. Warnings are fine until you reach the phase that needs them."
  exit 1
fi

echo "Ready."
