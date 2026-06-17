#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Install prerequisites for GitLab on Kubernetes via Helm
# Installs: kubectl, Helm 3, minikube (Docker driver — no root)
# ──────────────────────────────────────────────────────────────

HELM_VERSION="v3.17.3"
MINIKUBE_VERSION="v1.35.0"
GITLAB_K8S_VERSION="1.32"   # Kubernetes version minikube will run
INSTALL_DIR="${HOME}/.local/bin"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

arch() {
  local m; m=$(uname -m)
  [[ "$m" == "x86_64" ]] && echo "amd64" || echo "arm64"
}

install_kubectl() {
  if command -v kubectl &>/dev/null; then
    info "kubectl already installed: $(kubectl version --client 2>/dev/null | head -1)"
    return
  fi
  info "Installing kubectl..."
  KUBE_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
  curl -sSLo "${INSTALL_DIR}/kubectl" \
    "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/$(arch)/kubectl"
  chmod +x "${INSTALL_DIR}/kubectl"
  info "kubectl ${KUBE_VERSION} installed → ${INSTALL_DIR}/kubectl"
}

install_helm() {
  if command -v helm &>/dev/null; then
    info "Helm already installed: $(helm version --short)"
    return
  fi
  info "Installing Helm ${HELM_VERSION}..."
  curl -sSLo /tmp/helm.tar.gz \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-$(arch).tar.gz"
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mv "/tmp/linux-$(arch)/helm" "${INSTALL_DIR}/helm"
  rm -rf /tmp/helm.tar.gz "/tmp/linux-$(arch)"
  info "Helm ${HELM_VERSION} installed → ${INSTALL_DIR}/helm"
}

install_minikube() {
  if command -v minikube &>/dev/null && minikube status 2>/dev/null | grep -q "Running"; then
    info "minikube already running"
    return
  fi

  if ! command -v minikube &>/dev/null; then
    info "Installing minikube ${MINIKUBE_VERSION}..."
    curl -sSLo "${INSTALL_DIR}/minikube" \
      "https://storage.googleapis.com/minikube/releases/${MINIKUBE_VERSION}/minikube-linux-$(arch)"
    chmod +x "${INSTALL_DIR}/minikube"
    info "minikube ${MINIKUBE_VERSION} installed → ${INSTALL_DIR}/minikube"
  fi

  command -v docker &>/dev/null || error "Docker is required for the Docker driver. Install Docker first."

  info "Starting minikube (Docker driver, Kubernetes ${GITLAB_K8S_VERSION})..."
  minikube start \
    --driver=docker \
    --kubernetes-version="${GITLAB_K8S_VERSION}" \
    --cpus=4 \
    --memory=8192 \
    --disk-size=50g \
    --addons=ingress \
    --addons=ingress-dns \
    --addons=storage-provisioner \
    --profile=gitlab

  info "Waiting for cluster to be ready..."
  kubectl wait --for=condition=Ready nodes --all --timeout=120s
  info "minikube cluster 'gitlab' is ready"
}

add_gitlab_helm_repo() {
  info "Adding GitLab Helm repository..."
  helm repo add gitlab https://charts.gitlab.io/ 2>/dev/null || true
  helm repo update
  info "GitLab Helm repo ready"
}

print_system_check() {
  info "System resource check:"
  echo "  RAM   : $(free -h | awk '/^Mem:/{print $2}') total, $(free -h | awk '/^Mem:/{print $7}') available"
  echo "  CPUs  : $(nproc)"
  echo "  Disk  : $(df -h / | awk 'NR==2{print $4}') free on /"

  TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
  if (( TOTAL_RAM_MB < 8192 )); then
    warn "GitLab recommends ≥ 8 GB RAM. You have ${TOTAL_RAM_MB} MB."
  fi
}

ensure_install_dir() {
  mkdir -p "${INSTALL_DIR}"
  if ! echo "$PATH" | grep -q "${INSTALL_DIR}"; then
    warn "${INSTALL_DIR} is not in PATH. Adding to ~/.bashrc"
    echo "export PATH=\"${INSTALL_DIR}:\$PATH\"" >> ~/.bashrc
    export PATH="${INSTALL_DIR}:$PATH"
  fi
}

main() {
  ensure_install_dir
  print_system_check
  install_kubectl
  install_helm
  install_minikube
  add_gitlab_helm_repo
  echo ""
  info "All prerequisites ready. Run ./deploy.sh next:"
  echo "  ./deploy.sh --domain gitlab.local --ip \$(minikube ip --profile=gitlab) --email you@example.com --values-file values-local.yaml"
}

main "$@"
