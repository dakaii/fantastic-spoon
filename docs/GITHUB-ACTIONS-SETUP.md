# GitHub Actions setup (GCP)

Run deploy and destroy from GitHub’s cloud so you can close your laptop. Works on a **public repo** when secrets stay in GitHub Secrets (never commit keys).

**GCP project creation is not in GitHub Actions** — create the project once manually (Console or local script), then use Actions for deploy/destroy.

---

## Workflows

| Workflow | When to use |
|----------|-------------|
| **GCP Bootstrap** | Ansible/k3s only — VMs already exist, need (re)bootstrap |
| **GCP Deploy All** | Full stack: Terraform + bootstrap + Linkding apps |
| **GCP Destroy** | Tear down all resources (`terraform destroy`) |
| **Terraform Validate** | Automatic on PRs — no secrets |

---

## Prerequisites (one time, on your Mac)

### 1. Create GCP project manually

[Google Cloud Console](https://console.cloud.google.com) → New project → link billing.

Or locally (needs billing account ID):

```bash
GCP_PROJECT=hybrid-k8s-dev BILLING_ACCOUNT_ID=012345-678901-ABCDEF ./scripts/gcp-project-create.sh
```

### 2. GitHub secrets + service account

```bash
gcloud auth login
gh auth login

# Bootstrap-only SA (Compute Viewer):
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-setup-github-actions.sh --push-secrets

# Deploy + Destroy (Compute Admin, Storage Admin):
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-setup-github-actions.sh --full --push-secrets
```

| Secret | Required for |
|--------|----------------|
| `GCP_PROJECT` | All |
| `GCP_SA_KEY` | All |
| `SSH_PRIVATE_KEY` | Bootstrap, Deploy |
| `SSH_PUBLIC_KEY` | Deploy, Destroy |
| `ADMIN_CIDR` | Deploy (`0.0.0.0/0` for GitHub runners — set by script) |

### 3. Seed Terraform state (if you already deployed locally)

So Deploy/Destroy know what exists:

```bash
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-tfstate-sync.sh push
```

State is stored in `gs://YOUR_PROJECT-tfstate/`.

### 4. Open SSH firewall for GitHub runners

Edit `primary-cluster-gcp/terraform.tfvars`:

```hcl
admin_cidr = "0.0.0.0/0"
```

```bash
cd primary-cluster-gcp && terraform apply
```

---

## Run from GitHub or CLI

### Bootstrap only (your current situation)

**Run one workflow at a time.** Two concurrent bootstrap runs will fight over Helm and leave releases stuck (`another operation is in progress`).

```bash
gh workflow run gcp-bootstrap.yml -f cluster=primary -R dakaii/fantastic-spoon
gh run watch 29188090281 -R dakaii/fantastic-spoon   # watch a specific run ID
```

### Full deploy (greenfield or re-deploy)

Actions → **GCP Deploy All** → Run workflow

```bash
gh workflow run gcp-deploy-all.yml -R dakaii/fantastic-spoon
```

### Destroy everything (stop billing)

Actions → **GCP Destroy** → Run workflow

Optional: check **delete_project** to remove the GCP project too.

```bash
gh workflow run gcp-destroy.yml -R dakaii/fantastic-spoon
```

Tip: add a [GitHub Environment](https://docs.github.com/en/actions/deployment/targeting-different-environments) with required reviewers on **GCP Destroy**.

---

## Why no “create project” workflow?

Creating a GCP project requires **org/folder Project Creator** and **Billing Account User** permissions. A service account inside one project usually cannot create sibling projects. Create the project once manually, then automate deploy/destroy.

---

## Public repo safety

- Secrets only in GitHub Secrets — never in git
- Workflows are manual (`workflow_dispatch`) only
- Use a dedicated deploy SSH key + service account
- Consider Environment approval on **GCP Destroy**

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| SSH timeout | `admin_cidr = "0.0.0.0/0"` + `terraform apply` |
| Deploy tries to recreate VMs | Run `./scripts/gcp-tfstate-sync.sh push` from Mac first |
| Destroy does nothing | Same — state must be in GCS bucket |
| Ansible fails | Re-run **GCP Bootstrap** (idempotent) |
| Argo CD `failed pre-install` timeout | Fixed in bootstrap: skips `redis-secret-init` hook, pre-creates Redis secret. If stuck, `helm uninstall argocd -n argocd` then re-run bootstrap (CRDs are kept) |
| Cilium TLS / `certificate is valid for ... not <new-ip>` | Ephemeral GCP IP changed — Cilium must use **internal** API IP (`10.1.0.4`), not external NAT IP. Reinstall Cilium with `k8sServiceHost=10.1.0.4` (see docs) |
| `kubectl` / API timeouts on control plane | Control plane OOM on `e2-small` — resize to `e2-medium` (see below) |
| `gcloud` 403 wrong account | `GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-use-project.sh` |

### Resize an existing control plane (manual, one-time)

Repo defaults are updated for **new** deploys. VMs already running stay `e2-small` until you resize:

```bash
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-use-project.sh

gcloud compute instances stop hybrid-k8s-cp-1 --zone=us-central1-a --project=hybrid-k8s-dev
gcloud compute instances set-machine-type hybrid-k8s-cp-1 \
  --zone=us-central1-a --project=hybrid-k8s-dev --machine-type=e2-medium
gcloud compute instances start hybrid-k8s-cp-1 --zone=us-central1-a --project=hybrid-k8s-dev

ssh ubuntu@136.112.126.15 "sudo systemctl restart k3s && sleep 60 && sudo k3s kubectl get nodes"
```

Or change `control_plane_machine_type` in local `terraform.tfvars` and `terraform apply` (instance must be stopped).
