# Self-Hosted GitLab on Kubernetes (Helm)

Deploys the official [GitLab Helm chart](https://docs.gitlab.com/charts/) on a
single-node Linux host using k3s (lightweight Kubernetes).

---

## Requirements

| Resource | Minimum | Recommended |
|----------|---------|-------------|
| RAM      | 8 GB    | 16 GB       |
| CPU      | 4 cores | 8 cores     |
| Disk     | 50 GB   | 100 GB      |
| OS       | Ubuntu 20.04+ / Debian 11+ / RHEL 8+ | |

---

## Quick start

### 1 — Install tools (kubectl + Helm + k3s)

```bash
sudo ./install-tools.sh
```

This installs kubectl, Helm 3, and k3s with Traefik disabled (GitLab brings its
own nginx-ingress). The kubeconfig is written to `~/.kube/config`.

### 2 — Deploy GitLab

**Option A — Public server with a real domain and Let's Encrypt TLS**

```bash
./deploy.sh \
  --domain  example.com \
  --ip      1.2.3.4 \
  --email   admin@example.com
```

Point these DNS A-records at your server IP before TLS provisioning:

```
gitlab.example.com    →  1.2.3.4
registry.example.com  →  1.2.3.4
minio.example.com     →  1.2.3.4
```

**Option B — Local / LAN install (self-signed TLS, NodePort)**

```bash
./deploy.sh \
  --domain      my.lan \
  --ip          192.168.1.10 \
  --email       admin@local.lan \
  --values-file values-local.yaml
```

Add to `/etc/hosts` on every client:

```
192.168.1.10  gitlab.my.lan registry.my.lan minio.my.lan
```

Access via `https://gitlab.my.lan:30443` (browser will warn about self-signed cert).

**Option C — Upgrade an existing install**

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
```

---

## Tear down

> **Warning:** This permanently deletes all GitLab data.

```bash
./teardown.sh
```

---

## File layout

```
.
├── install-tools.sh    # Installs kubectl, Helm, k3s
├── deploy.sh           # Helm install / upgrade
├── backup.sh           # Trigger a GitLab backup
├── teardown.sh         # Remove everything
├── values.yaml         # Helm values — public domain + Let's Encrypt
├── values-local.yaml   # Helm values — LAN / self-signed TLS
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

---

## Author

**rejRoky** — [github.com/rejRoky](https://github.com/rejRoky)

## License

[MIT](LICENSE) © 2026 rejRoky

Then run `./deploy.sh ... --upgrade`.
