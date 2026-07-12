# GitHub Actions setup (GCP bootstrap)

Run k3s bootstrap from GitHub’s cloud so you can close your laptop. Works on a **public repo** when secrets stay in GitHub Secrets (never commit keys).

---

## Workflows

| Workflow | Trigger | What it does |
|----------|---------|--------------|
| **GCP Bootstrap** (`gcp-bootstrap.yml`) | Manual | Inventory from live GCE → Ansible bootstrap (**use this now**) |
| **GCP Deploy (Experimental)** (`gcp-deploy.yml`) | Manual | Full Terraform + bootstrap (needs shared Terraform state) |
| **Terraform Validate** (`terraform-validate.yml`) | Every PR | `terraform validate` only — no secrets |

---

## One-time setup (~15 minutes)

### Quick setup (script)

From your Mac (after `gcloud auth login`):

```bash
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-setup-github-actions.sh --push-secrets
```

This creates the `github-actions` service account, downloads a JSON key to `.secrets/` (gitignored), and pushes GitHub secrets via `gh` CLI.

For full Terraform deploy workflow later, add `--full`:

```bash
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-setup-github-actions.sh --full --push-secrets
```

### Manual setup (alternative)

#### 1. Create a GCP service account

In [GCP Console → IAM → Service Accounts](https://console.cloud.google.com/iam-admin/serviceaccounts) (project `hybrid-k8s-dev`):

1. **Create service account** — name: `github-actions`
2. **Grant roles:**
   - Compute Viewer (read VMs + LB for inventory)
   - Compute Admin (only if you use the full deploy workflow)
   - Storage Admin (only for full deploy + Velero)
3. **Keys → Add key → JSON** — download the file (keep it private)

For **bootstrap-only**, `Compute Viewer` is enough. Use the broader roles if you plan to run the full deploy workflow later.

### 2. SSH key pair (deploy-only)

Use the **same key pair** already in your `terraform.tfvars` (`ssh_public_key`), or create a dedicated deploy key:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hybrid-k8s-deploy -N ""
cat ~/.ssh/hybrid-k8s-deploy.pub    # → SSH_PUBLIC_KEY secret (optional)
cat ~/.ssh/hybrid-k8s-deploy        # → SSH_PRIVATE_KEY secret
```

If you create a new pair, update `ssh_public_key` in `primary-cluster-gcp/terraform.tfvars` and run `terraform apply` so VMs accept the new key.

### 3. Add GitHub repository secrets

Repo → **Settings → Secrets and variables → Actions → New repository secret**

| Secret | Value |
|--------|--------|
| `GCP_PROJECT` | `hybrid-k8s-dev` |
| `GCP_SA_KEY` | Entire JSON key file contents |
| `SSH_PRIVATE_KEY` | Private key (full PEM, including `-----BEGIN...`) |

Optional (full deploy workflow only):

| Secret | Value |
|--------|--------|
| `SSH_PUBLIC_KEY` | Public key line |
| `ADMIN_CIDR` | CIDR that can SSH to VMs (see firewall below) |

**CLI alternative** (from your Mac, with [gh](https://cli.github.com/) authenticated):

```bash
gh secret set GCP_PROJECT -b "hybrid-k8s-dev" -R dakaii/fantastic-spoon
gh secret set GCP_SA_KEY    < path/to/sa-key.json -R dakaii/fantastic-spoon
gh secret set SSH_PRIVATE_KEY < ~/.ssh/id_ed25519 -R dakaii/fantastic-spoon
```

### 4. Open SSH firewall to GitHub Actions

VMs only allow SSH from `admin_cidr` in Terraform. GitHub-hosted runners use **different IPs** than your Mac.

**Option A — Dev / learning (simplest):** allow SSH from anywhere temporarily.

Edit `primary-cluster-gcp/terraform.tfvars`:

```hcl
admin_cidr = "0.0.0.0/0"
```

Then:

```bash
cd primary-cluster-gcp && terraform apply
```

Use a strong deploy-only SSH key. Tighten `admin_cidr` later.

**Option B — Self-hosted runner on GCE (better):** run Actions on a small VM in your project; set `admin_cidr` to that VM’s IP only.

**Option C — GitHub IP ranges:** [GitHub meta API](https://api.github.com/meta) lists `actions` CIDRs (large, changes). Possible but awkward for a solo project.

---

## Run bootstrap (close laptop after this)

1. Stop any local `./scripts/bootstrap-cluster.sh` run on your Mac (avoid two Ansible controllers).
2. GitHub → **Actions** → **GCP Bootstrap** → **Run workflow**
3. Cluster: `primary` → **Run workflow**
4. Watch logs in the browser (~15–30 min for full Ansible + Helm add-ons).

When it finishes, verify from your Mac:

```bash
ssh ubuntu@136.112.126.15 "sudo k3s kubectl get nodes"
```

---

## Public repo safety checklist

- Secrets only in **GitHub Secrets** — never in git or workflow YAML
- Workflows use **`workflow_dispatch` only** (manual) — not triggered by untrusted PRs
- Use a **dedicated** GCP service account + deploy SSH key (not your daily personal keys)
- Prefer **bootstrap workflow** over storing JSON keys in more places than needed
- For production: private repo, [Workload Identity Federation](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines), narrow firewall rules

---

## Troubleshooting

**SSH timeout in workflow**

- `admin_cidr` does not include GitHub runner IPs → apply Option A or B above
- Wrong `SSH_PRIVATE_KEY` (doesn’t match VM `ssh_public_key`)

**No instances found**

- Wrong `GCP_PROJECT` secret
- Service account missing `Compute Viewer`

**Ansible fails mid-run**

- Re-run **GCP Bootstrap** — Ansible is idempotent
- Check VM logs: `ssh ubuntu@<ip> sudo journalctl -u k3s -f`

**Full deploy workflow (`gcp-deploy.yml`)**

- Requires Terraform state shared with CI (e.g. GCS backend). Bootstrap workflow does **not** need local tfstate.

---

## After bootstrap

Deploy apps (still local for now):

```bash
./scripts/gcp-deploy.sh apps
```

Or add an `apps` workflow later.
