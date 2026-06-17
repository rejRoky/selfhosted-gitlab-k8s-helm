#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Deploy self-hosted GitLab on Kubernetes using the official
# Helm chart (gitlab/gitlab).
#
# Usage:
#   ./deploy.sh                     # interactive — prompts for domain/IP
#   ./deploy.sh --domain example.com --ip 1.2.3.4 --email admin@example.com
#   ./deploy.sh --upgrade           # upgrade an existing installation
# ──────────────────────────────────────────────────────────────

NAMESPACE="gitlab"
RELEASE_NAME="gitlab"
CHART="gitlab/gitlab"
CHART_VERSION=""          # Pin to a specific chart version, e.g. "8.11.2"
TIMEOUT="600s"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
step()    { echo -e "\n${CYAN}══ $* ══${NC}"; }

# ── Argument parsing ─────────────────────────────────────────
DOMAIN=""
EXTERNAL_IP=""
EMAIL=""
UPGRADE=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --domain)      DOMAIN="$2";       shift 2 ;;
    --ip)          EXTERNAL_IP="$2";  shift 2 ;;
    --email)       EMAIL="$2";        shift 2 ;;
    --upgrade)     UPGRADE=true;      shift   ;;
    --values-file) VALUES_FILE="$2";  shift 2 ;;
    *) error "Unknown flag: $1. Use --domain, --ip, --email, --upgrade, --values-file" ;;
  esac
done

# ── Interactive prompts when flags not supplied ───────────────
prompt_if_empty() {
  local var_name="$1" prompt_text="$2" default_val="${3:-}"
  if [[ -z "${!var_name}" ]]; then
    if [[ -n "$default_val" ]]; then
      read -rp "$(echo -e "${CYAN}${prompt_text} [${default_val}]: ${NC}")" input
      printf -v "$var_name" '%s' "${input:-$default_val}"
    else
      while [[ -z "${!var_name}" ]]; do
        read -rp "$(echo -e "${CYAN}${prompt_text}: ${NC}")" input
        printf -v "$var_name" '%s' "$input"
      done
    fi
  fi
}

prompt_if_empty DOMAIN      "GitLab domain (e.g. example.com)"
prompt_if_empty EXTERNAL_IP "Node public IP (for DNS)"
prompt_if_empty EMAIL       "Email for Let's Encrypt ACME"

# ── Validation ───────────────────────────────────────────────
[[ "$DOMAIN"      =~ ^[a-zA-Z0-9._-]+\.[a-zA-Z]{2,}$ ]] || error "Invalid domain: $DOMAIN"
[[ "$EXTERNAL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || error "Invalid IP: $EXTERNAL_IP"
[[ "$EMAIL"       =~ ^[^@]+@[^@]+\.[^@]+$              ]] || error "Invalid email: $EMAIL"

# ── Prerequisite checks ───────────────────────────────────────
step "Checking prerequisites"
command -v kubectl &>/dev/null || error "kubectl not found. Run ./install-tools.sh first."
command -v helm    &>/dev/null || error "helm not found. Run ./install-tools.sh first."
kubectl cluster-info &>/dev/null        || error "Cannot reach Kubernetes cluster. Check KUBECONFIG."
[[ -f "$VALUES_FILE" ]]                 || error "values.yaml not found at $VALUES_FILE"

info "Kubernetes cluster: $(kubectl config current-context)"
info "Domain  : $DOMAIN"
info "Node IP : $EXTERNAL_IP"
info "Email   : $EMAIL"

# ── Helm repo ─────────────────────────────────────────────────
step "Updating Helm repos"
helm repo add gitlab https://charts.gitlab.io/ 2>/dev/null || true
helm repo update

# ── Namespace ─────────────────────────────────────────────────
step "Creating namespace"
kubectl apply -f "${SCRIPT_DIR}/k8s/namespace.yaml"

# ── Build helm flags ─────────────────────────────────────────
HELM_ARGS=(
  --namespace   "$NAMESPACE"
  --timeout     "$TIMEOUT"
  --values      "$VALUES_FILE"
  --set "global.hosts.domain=${DOMAIN}"
  --set "global.hosts.externalIP=${EXTERNAL_IP}"
  --set "certmanager-issuer.email=${EMAIL}"
  --wait
  --atomic       # Roll back automatically on failure
)
[[ -n "$CHART_VERSION" ]] && HELM_ARGS+=(--version "$CHART_VERSION")

# ── Deploy or upgrade ─────────────────────────────────────────
if $UPGRADE; then
  step "Upgrading GitLab Helm release"
  helm upgrade "$RELEASE_NAME" "$CHART" "${HELM_ARGS[@]}"
else
  if helm status "$RELEASE_NAME" -n "$NAMESPACE" &>/dev/null; then
    warn "Release '$RELEASE_NAME' already exists in namespace '$NAMESPACE'."
    warn "Use --upgrade to upgrade it, or run ./teardown.sh to remove it first."
    exit 1
  fi
  step "Installing GitLab Helm release (this takes 8–15 minutes)"
  helm install "$RELEASE_NAME" "$CHART" "${HELM_ARGS[@]}"
fi

# ── Post-deploy info ──────────────────────────────────────────
step "Deployment complete"

echo ""
info "DNS records to create (A records):"
echo "  gitlab.${DOMAIN}    →  ${EXTERNAL_IP}"
echo "  registry.${DOMAIN}  →  ${EXTERNAL_IP}"
echo "  minio.${DOMAIN}     →  ${EXTERNAL_IP}"
echo ""

info "Fetching initial root password..."
ROOT_PASSWORD=""
for i in {1..10}; do
  ROOT_PASSWORD=$(kubectl get secret "${RELEASE_NAME}-gitlab-initial-root-password" \
    -n "$NAMESPACE" -o jsonpath='{.data.password}' 2>/dev/null | base64 --decode) && break
  sleep 5
done

if [[ -n "$ROOT_PASSWORD" ]]; then
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║  GitLab is ready!                                    ║${NC}"
  echo -e "${GREEN}╠══════════════════════════════════════════════════════╣${NC}"
  echo -e "${GREEN}║  URL      : https://gitlab.${DOMAIN}${NC}"
  echo -e "${GREEN}║  Username : root                                     ║${NC}"
  echo -e "${GREEN}║  Password : ${ROOT_PASSWORD}${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
  echo ""
  warn "Change the root password immediately after first login!"
else
  info "Access GitLab at https://gitlab.${DOMAIN}"
  info "Get the root password with:"
  echo "  kubectl get secret ${RELEASE_NAME}-gitlab-initial-root-password \\"
  echo "    -n ${NAMESPACE} -o jsonpath='{.data.password}' | base64 --decode"
fi

echo ""
info "Useful commands:"
echo "  kubectl get pods -n ${NAMESPACE}                  # watch pod status"
echo "  kubectl logs -n ${NAMESPACE} deploy/${RELEASE_NAME}-webservice-default   # app logs"
echo "  helm status ${RELEASE_NAME} -n ${NAMESPACE}       # release status"
echo "  helm get values ${RELEASE_NAME} -n ${NAMESPACE}   # current values"
