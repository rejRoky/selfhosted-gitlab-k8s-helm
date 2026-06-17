#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Install prerequisites for GitLab on Kubernetes via Helm
# Installs: kubectl, Helm 3, k3s (lightweight Kubernetes)
# ──────────────────────────────────────────────────────────────

HELM_VERSION="v3.17.3"
K3S_VERSION="v1.32.4+k3s1"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

require_root() {
  [[ $EUID -eq 0 ]] || error "Run this script as root: sudo $0"
}

install_kubectl() {
  if command -v kubectl &>/dev/null; then
    info "kubectl already installed: $(kubectl version --client --short 2>/dev/null)"
    return
  fi
  info "Installing kubectl..."
  ARCH=$(uname -m); [[ $ARCH == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
  KUBE_VERSION=$(curl -sSL https://dl.k8s.io/release/stable.txt)
  curl -sSLo /usr/local/bin/kubectl \
    "https://dl.k8s.io/release/${KUBE_VERSION}/bin/linux/${ARCH}/kubectl"
  chmod +x /usr/local/bin/kubectl
  info "kubectl ${KUBE_VERSION} installed"
}

install_helm() {
  if command -v helm &>/dev/null; then
    info "Helm already installed: $(helm version --short)"
    return
  fi
  info "Installing Helm ${HELM_VERSION}..."
  ARCH=$(uname -m); [[ $ARCH == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
  curl -sSLo /tmp/helm.tar.gz \
    "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  tar -xzf /tmp/helm.tar.gz -C /tmp
  mv /tmp/linux-${ARCH}/helm /usr/local/bin/helm
  rm -rf /tmp/helm.tar.gz /tmp/linux-${ARCH}
  info "Helm ${HELM_VERSION} installed"
}

install_k3s() {
  if command -v k3s &>/dev/null && k3s kubectl get nodes &>/dev/null 2>&1; then
    info "k3s already running"
    return
  fi

  info "Installing k3s ${K3S_VERSION}..."
  # Disable Traefik — GitLab chart brings its own nginx-ingress
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_EXEC="server \
      --disable traefik \
      --disable servicelb \
      --write-kubeconfig-mode 644 \
      --kube-apiserver-arg=service-node-port-range=1-65535" \
    sh -

  info "Waiting for k3s to become ready..."
  until k3s kubectl get nodes 2>/dev/null | grep -q " Ready"; do sleep 3; done
  info "k3s is ready"

  # Make kubeconfig available system-wide
  mkdir -p /root/.kube
  cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
  chmod 600 /root/.kube/config

  # Also write for the invoking sudo user if SUDO_USER is set
  if [[ -n "${SUDO_USER:-}" ]]; then
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    mkdir -p "${REAL_HOME}/.kube"
    cp /etc/rancher/k3s/k3s.yaml "${REAL_HOME}/.kube/config"
    chown "${SUDO_USER}:${SUDO_USER}" "${REAL_HOME}/.kube/config"
    chmod 600 "${REAL_HOME}/.kube/config"
    info "kubeconfig written to ${REAL_HOME}/.kube/config"
  fi
}

add_gitlab_helm_repo() {
  info "Adding GitLab Helm repository..."
  helm repo add gitlab https://charts.gitlab.io/ 2>/dev/null || true
  helm repo update
}

print_system_check() {
  info "System resource check:"
  echo "  RAM   : $(free -h | awk '/^Mem:/{print $2}') total, $(free -h | awk '/^Mem:/{print $7}') available"
  echo "  CPUs  : $(nproc)"
  echo "  Disk  : $(df -h / | awk 'NR==2{print $4}') free on /"

  TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
  if (( TOTAL_RAM_MB < 8192 )); then
    warn "GitLab recommends ≥ 8 GB RAM. You have ${TOTAL_RAM_MB} MB."
    warn "Consider reducing replicas and enabling swap, or use a smaller node."
  fi
}

main() {
  require_root
  print_system_check
  install_kubectl
  install_helm
  install_k3s
  add_gitlab_helm_repo
  info "All prerequisites installed. Run ./deploy.sh next."
}

main "$@"
