#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Tear down the GitLab Helm deployment.
# WARNING: This deletes all GitLab data permanently.
# ──────────────────────────────────────────────────────────────

NAMESPACE="gitlab"
RELEASE_NAME="gitlab"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

echo -e "${RED}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║  WARNING: This will permanently delete GitLab and   ║"
echo "  ║  all its data (repositories, CI pipelines, etc.).   ║"
echo "  ╚══════════════════════════════════════════════════════╝"
echo -e "${NC}"
read -rp "Type 'delete-gitlab' to confirm: " CONFIRM
[[ "$CONFIRM" == "delete-gitlab" ]] || { info "Aborted."; exit 0; }

command -v helm    &>/dev/null || error "helm not found"
command -v kubectl &>/dev/null || error "kubectl not found"

info "Uninstalling Helm release '${RELEASE_NAME}' from namespace '${NAMESPACE}'..."
helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" 2>/dev/null && \
  info "Helm release removed" || warn "Release not found or already removed"

info "Deleting remaining PersistentVolumeClaims..."
kubectl delete pvc --all -n "$NAMESPACE" --timeout=60s 2>/dev/null || true

info "Deleting namespace '${NAMESPACE}'..."
kubectl delete namespace "$NAMESPACE" --timeout=120s 2>/dev/null || true

info "Removing GitLab Helm repo..."
helm repo remove gitlab 2>/dev/null || true

info "Teardown complete."
