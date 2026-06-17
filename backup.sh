#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Run a GitLab backup using the Toolbox pod.
# Backup is stored in the MinIO/object-storage bucket.
# ──────────────────────────────────────────────────────────────

NAMESPACE="gitlab"
RELEASE_NAME="gitlab"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "\n${CYAN}══ $* ══${NC}"; }

TOOLBOX_POD=$(kubectl get pod \
  -n "$NAMESPACE" \
  -l "app=toolbox,release=${RELEASE_NAME}" \
  -o jsonpath='{.items[0].metadata.name}')

[[ -n "$TOOLBOX_POD" ]] || { echo "Toolbox pod not found in namespace $NAMESPACE"; exit 1; }

step "Starting GitLab backup (pod: $TOOLBOX_POD)"
kubectl exec -n "$NAMESPACE" "$TOOLBOX_POD" -- \
  backup-utility

info "Backup complete. Use 'backup-utility --restore' to restore."
info ""
info "To list backups in object storage:"
echo "  kubectl exec -n ${NAMESPACE} ${TOOLBOX_POD} -- backup-utility --list-backups"
info ""
info "To restore from a specific backup:"
echo "  kubectl exec -n ${NAMESPACE} ${TOOLBOX_POD} -- \\"
echo "    backup-utility --restore -t <BACKUP_TIMESTAMP>"
