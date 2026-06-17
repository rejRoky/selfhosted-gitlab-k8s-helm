#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Deploy GitLab external dependencies:
#   PostgreSQL, Redis, MinIO (via Bitnami Helm charts)
# Creates all Kubernetes secrets GitLab expects.
# Run this before deploy.sh.
# ──────────────────────────────────────────────────────────────

NAMESPACE="gitlab"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*"; }
step() { echo -e "\n${CYAN}══ $* ══${NC}"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

command -v helm    &>/dev/null || error "helm not found. Run ./install-tools.sh first."
command -v kubectl &>/dev/null || error "kubectl not found."
kubectl cluster-info &>/dev/null || error "No Kubernetes cluster reachable."

# ── Generate random passwords (idempotent: reuse if secret exists) ──
get_or_create_secret_value() {
  local secret_name="$1" key="$2" default_gen="$3"
  kubectl get secret "$secret_name" -n "$NAMESPACE" \
    -o jsonpath="{.data.${key}}" 2>/dev/null \
    | base64 --decode 2>/dev/null \
    || echo "$default_gen"
}

PG_PASSWORD=$(get_or_create_secret_value gitlab-postgresql password "$(openssl rand -hex 16)")
REDIS_PASSWORD=$(get_or_create_secret_value gitlab-redis redis-password "$(openssl rand -hex 16)")
MINIO_ROOT_USER="gitlabminio"
MINIO_ROOT_PASSWORD=$(get_or_create_secret_value gitlab-minio-credentials rootPassword "$(openssl rand -hex 24)")

MINIO_BUCKETS="gitlab-lfs\,gitlab-artifacts\,gitlab-uploads\,gitlab-packages\,gitlab-backup\,gitlab-tmp\,gitlab-registry"

# ── Helm repos ────────────────────────────────────────────────
step "Adding Helm repos"
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add minio   https://charts.min.io/             2>/dev/null || true
helm repo add gitlab  https://charts.gitlab.io/          2>/dev/null || true
helm repo update

# ── PostgreSQL ───────────────────────────────────────────────
step "Deploying PostgreSQL"
helm upgrade --install gitlab-postgresql bitnami/postgresql \
  --namespace "$NAMESPACE" \
  --set auth.username=gitlab \
  --set auth.password="$PG_PASSWORD" \
  --set auth.database=gitlabhq_production \
  --set primary.persistence.size=8Gi \
  --set primary.resources.requests.cpu=200m \
  --set primary.resources.requests.memory=256Mi \
  --wait --timeout=180s

kubectl create secret generic gitlab-postgresql \
  --namespace "$NAMESPACE" \
  --from-literal=password="$PG_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

info "PostgreSQL ready at gitlab-postgresql.$NAMESPACE.svc.cluster.local:5432"

# ── Redis ─────────────────────────────────────────────────────
step "Deploying Redis"
helm upgrade --install gitlab-redis bitnami/redis \
  --namespace "$NAMESPACE" \
  --set auth.password="$REDIS_PASSWORD" \
  --set architecture=standalone \
  --set master.persistence.size=5Gi \
  --set master.resources.requests.cpu=100m \
  --set master.resources.requests.memory=128Mi \
  --wait --timeout=180s

kubectl create secret generic gitlab-redis \
  --namespace "$NAMESPACE" \
  --from-literal=redis-password="$REDIS_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Redis ready at gitlab-redis-master.$NAMESPACE.svc.cluster.local:6379"

# ── MinIO (official chart — quay.io/minio/minio, no auth wall) ──
step "Deploying MinIO"
helm upgrade --install gitlab-minio minio/minio \
  --namespace "$NAMESPACE" \
  --set rootUser="$MINIO_ROOT_USER" \
  --set rootPassword="$MINIO_ROOT_PASSWORD" \
  --set persistence.size=20Gi \
  --set mode=standalone \
  --set service.type=ClusterIP \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=256Mi \
  --wait --timeout=180s

kubectl create secret generic gitlab-minio-credentials \
  --namespace "$NAMESPACE" \
  --from-literal=rootUser="$MINIO_ROOT_USER" \
  --from-literal=rootPassword="$MINIO_ROOT_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

MINIO_HOST="gitlab-minio.$NAMESPACE.svc.cluster.local"
MINIO_ENDPOINT="http://${MINIO_HOST}:9000"

info "MinIO ready at ${MINIO_ENDPOINT}"

# ── Create MinIO buckets via a one-shot Job ───────────────────
step "Creating MinIO buckets"
kubectl apply -f - <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: gitlab-minio-bucket-init
  namespace: ${NAMESPACE}
spec:
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: mc
        image: quay.io/minio/mc:latest
        command:
        - /bin/sh
        - -c
        - |
          mc alias set minio http://gitlab-minio:9000 \${MINIO_ROOT_USER} \${MINIO_ROOT_PASSWORD}
          for b in gitlab-lfs gitlab-artifacts gitlab-uploads gitlab-packages gitlab-backup gitlab-tmp gitlab-registry; do
            mc mb --ignore-existing minio/\$b
          done
          echo "Buckets created."
        env:
        - name: MINIO_ROOT_USER
          valueFrom:
            secretKeyRef:
              name: gitlab-minio-credentials
              key: rootUser
        - name: MINIO_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: gitlab-minio-credentials
              key: rootPassword
YAML

info "Waiting for bucket init job..."
kubectl wait --for=condition=complete job/gitlab-minio-bucket-init \
  -n "$NAMESPACE" --timeout=120s && info "Buckets ready"

# ── Object storage connection secret (Rails app) ─────────────
step "Creating object storage secrets"
kubectl create secret generic gitlab-object-store \
  --namespace "$NAMESPACE" \
  --from-literal=connection="$(cat <<EOF
provider: AWS
region: us-east-1
aws_access_key_id: ${MINIO_ROOT_USER}
aws_secret_access_key: ${MINIO_ROOT_PASSWORD}
aws_signature_version: 4
host: ${MINIO_HOST}
endpoint: ${MINIO_ENDPOINT}
path_style: true
EOF
)" \
  --dry-run=client -o yaml | kubectl apply -f -

# ── Registry storage secret ───────────────────────────────────
kubectl create secret generic gitlab-registry-storage \
  --namespace "$NAMESPACE" \
  --from-literal=config="$(cat <<EOF
s3:
  bucket: gitlab-registry
  accesskey: ${MINIO_ROOT_USER}
  secretkey: ${MINIO_ROOT_PASSWORD}
  regionendpoint: ${MINIO_ENDPOINT}
  region: us-east-1
  v4auth: true
  pathstyle: true
EOF
)" \
  --dry-run=client -o yaml | kubectl apply -f -

info "Secrets created: gitlab-postgresql, gitlab-redis, gitlab-object-store, gitlab-registry-storage"

# ── Summary ───────────────────────────────────────────────────
step "Dependencies ready"
echo ""
echo "  PostgreSQL : gitlab-postgresql.${NAMESPACE}.svc.cluster.local:5432"
echo "  Redis      : gitlab-redis-master.${NAMESPACE}.svc.cluster.local:6379"
echo "  MinIO      : ${MINIO_ENDPOINT}"
echo ""
info "Run ./deploy.sh next to install GitLab."
