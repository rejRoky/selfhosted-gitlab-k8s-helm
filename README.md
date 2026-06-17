# Self-Hosted GitLab on Kubernetes (Helm)

Deploys the official [GitLab Helm chart](https://docs.gitlab.com/charts/) on a
single-node Linux host using minikube (Docker driver — no root required).
PostgreSQL, Redis, and MinIO are deployed as separate Helm releases before
GitLab so they can be managed and upgraded independently.

---

## Requirements

| Resource | Minimum                               | Recommended |
|----------|---------------------------------------|-------------|
| RAM      | 8 GB                                  | 16 GB       |
| CPU      | 4 cores                               | 8 cores     |
| Disk     | 50 GB                                 | 100 GB      |
| OS       | Ubuntu 20.04+ / Debian 11+ / RHEL 8+  | —           |

Docker must be installed and the current user must be in the `docker` group.

---

## Quick start

### 1 — Install tools (kubectl + Helm + minikube)

```bash
./install-tools.sh
```

Installs kubectl, Helm 3, and minikube (Docker driver, Kubernetes 1.32) into
`~/.local/bin`. No `sudo` needed. Starts a minikube cluster named `gitlab`
with 4 CPUs, 8 GB RAM, and 50 GB disk.

### 2 — Deploy external dependencies (PostgreSQL, Redis, MinIO)

```bash
./deploy-deps.sh
```

Deploys the three stateful services that GitLab relies on as independent Helm
releases (`gitlab-postgresql`, `gitlab-redis`, `gitlab-minio`) in the `gitlab`
namespace, and creates all Kubernetes secrets GitLab expects.

### 3 — Deploy GitLab

#### Option A — Public server with a real domain and Let's Encrypt TLS

```bash
./deploy.sh \
  --domain  example.com \
  --ip      1.2.3.4 \
  --email   admin@example.com
```

Point these DNS A-records at your server IP before TLS provisioning:

```text
gitlab.example.com    →  1.2.3.4
registry.example.com  →  1.2.3.4
minio.example.com     →  1.2.3.4
```

#### Option B — Local / LAN install (self-signed TLS, NodePort)

```bash
./deploy.sh \
  --domain      my.lan \
  --ip          $(minikube ip --profile=gitlab) \
  --email       admin@local.lan \
  --values-file values-local.yaml
```

Add to `/etc/hosts` on every client:

```text
<minikube-ip>  gitlab.my.lan registry.my.lan minio.my.lan
```

Access via `https://gitlab.my.lan:30443` (browser will warn about self-signed
cert). SSH clone port is `32222`.

#### Option C — Upgrade an existing install

```bash
./deploy.sh --domain example.com --ip 1.2.3.4 --email admin@example.com --upgrade
```

---

## First login

After the deploy script finishes it prints the initial root password.
You can also retrieve it manually:

```bash
kubectl get secret gitlab-gitlab-initial-root-password \
  -n gitlab -o jsonpath='{.data.password}' | base64 --decode
```

Login at `https://gitlab.<your-domain>` with username `root`.
**Change the password immediately.**

---

## Backup & restore

```bash
# Create a backup (stored in MinIO object storage)
./backup.sh

# List backups
kubectl exec -n gitlab \
  $(kubectl get pod -n gitlab -l app=toolbox -o jsonpath='{.items[0].metadata.name}') \
  -- backup-utility --list-backups

# Restore from a specific backup timestamp
kubectl exec -n gitlab \
  $(kubectl get pod -n gitlab -l app=toolbox -o jsonpath='{.items[0].metadata.name}') \
  -- backup-utility --restore -t <TIMESTAMP>
```

---

## Useful commands

```bash
# Watch pods come up
kubectl get pods -n gitlab -w

# GitLab application logs
kubectl logs -n gitlab deploy/gitlab-webservice-default -f

# Sidekiq logs
kubectl logs -n gitlab deploy/gitlab-sidekiq-all-in-1-v2 -f

# Current Helm values
helm get values gitlab -n gitlab

# Helm release status
helm status gitlab -n gitlab

# Scale webservice replicas
kubectl scale deploy gitlab-webservice-default -n gitlab --replicas=2

# Get minikube cluster IP
minikube ip --profile=gitlab
```

---

## Tear down

> **Warning:** This permanently deletes all GitLab data.

```bash
./teardown.sh
```

To also remove the minikube cluster entirely:

```bash
minikube stop --profile=gitlab
minikube delete --profile=gitlab
```

---

## File layout

```text
.
├── install-tools.sh    # Installs kubectl, Helm, minikube (no root)
├── deploy-deps.sh      # Deploys PostgreSQL, Redis, MinIO + secrets
├── deploy.sh           # Helm install / upgrade for GitLab
├── backup.sh           # Trigger a GitLab backup via Toolbox pod
├── teardown.sh         # Remove all Helm releases and namespace
├── values.yaml         # Helm values — public domain + Let's Encrypt
├── values-local.yaml   # Helm values — LAN / NodePort / self-signed TLS
└── k8s/
    ├── namespace.yaml      # gitlab namespace
    └── cert-issuer.yaml    # Optional standalone ClusterIssuer
```

---

## Enabling the GitLab Runner (CI/CD)

Edit `values.yaml` and set:

```yaml
gitlab-runner:
  enabled: true
  rbac:
    create: true
  runners:
    config: |
      [[runners]]
        [runners.kubernetes]
          namespace = "gitlab"
          image = "ubuntu:22.04"
```

Then run `./deploy.sh ... --upgrade`.

---

## Author

**rejRoky** — [github.com/rejRoky](https://github.com/rejRoky)

## License

[MIT](LICENSE) © 2026 rejRoky
