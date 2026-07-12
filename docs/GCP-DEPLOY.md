# Deploying on GCP

Two ways to run this platform: **local scripts** (recommended first) and **GitHub Actions** (optional CI/CD).

---

## Is gitignoring `terraform.tfvars` common?

**Yes — standard practice.**

| File | Committed? | Why |
|------|------------|-----|
| `terraform.tfvars.example` | Yes | Documents required variables with placeholders |
| `terraform.tfvars` | **No** (gitignored) | Contains project ID, your IP, SSH key — machine-specific |
| `config/clusters.yaml` | **No** (gitignored) | Local cluster topology |

Same pattern as `.env` / `.env.example`. Never commit real tfvars.

---

## Authentication — no email in git

Your Google account is only used when you run:

```bash
./scripts/gcp-auth.sh
# or
./scripts/gcp-deploy.sh auth
```

That opens a browser, you sign in, and credentials are stored **locally** under `~/.config/gcloud/`. Terraform reads Application Default Credentials automatically.

**Nothing about your email or password goes into this repository.**

---

## Local deploy (recommended for first time)

Best for: learning, first cluster, debugging Terraform/Ansible, no GitHub secrets setup.

```bash
chmod +x scripts/gcp-*.sh scripts/phase*.sh

# Full interactive deploy (login → config → infra → Linkding app)
./scripts/gcp-deploy.sh

# Or step by step:
./scripts/gcp-deploy.sh auth    # browser login
./scripts/gcp-deploy.sh init    # create local terraform.tfvars
./scripts/gcp-deploy.sh infra   # GCE primary + standby + GCS
./scripts/gcp-deploy.sh apps    # Argo CD + Linkding
```

Optional env vars to skip prompts:

```bash
export GCP_PROJECT=hybrid-k8s-dev
export ADMIN_CIDR=203.0.113.10/32
export SSH_PUBLIC_KEY="$(cat ~/.ssh/id_ed25519.pub)"
./scripts/gcp-deploy.sh init
```

**Rough time:** 15–30 minutes (mostly waiting for VMs and Ansible).

**Cost:** ~$39–51/month while running — destroy with `terraform destroy` in each module when idle.

---

## GitHub Actions (optional)

Best for: validating Terraform on every PR, team workflows, repeatable deploys after infra exists.

| Use case | Local script | GitHub Actions |
|----------|--------------|----------------|
| First deploy / learning | ✅ Better | ❌ Overkill |
| PR checks (terraform validate) | Manual | ✅ Automated |
| Deploy from git push | Possible | ✅ With setup |
| Secrets in GitHub | None needed | GCP SA or Workload Identity |
| Debugging failures | Easy (SSH, logs) | Harder |

This repo includes:

- **`terraform-validate.yml`** — runs on every PR (no GCP secrets needed)
- **`gcp-bootstrap.yml`** — manual bootstrap on existing GCE VMs
- **`gcp-deploy-all.yml`** — manual full deploy (Terraform + Ansible + apps)
- **`gcp-destroy.yml`** — manual teardown (`terraform destroy`)

See **[GITHUB-ACTIONS-SETUP.md](GITHUB-ACTIONS-SETUP.md)** for step-by-step secret setup.

**Note:** GCP project creation is manual (Console). GitHub Actions handles deploy and destroy only.

### Setting up GitHub Actions bootstrap (recommended)

1. Create a GCP service account (see [GITHUB-ACTIONS-SETUP.md](GITHUB-ACTIONS-SETUP.md))
2. Store in GitHub repo secrets: `GCP_PROJECT`, `GCP_SA_KEY`, `SSH_PRIVATE_KEY`
3. Open SSH firewall (`admin_cidr`) so GitHub runners can reach VMs
4. Run **Actions → GCP Bootstrap → Run workflow** (cluster: `primary`)

For full Terraform deploy from CI (advanced), also add `SSH_PUBLIC_KEY`, `ADMIN_CIDR`, and configure remote Terraform state.

### Setting up full GitHub Actions deploy (advanced)

**Note:** The GHA workflow only supports `infra` (not `apps`). Run `./scripts/gcp-deploy.sh apps` locally after infra succeeds.

**Recommendation:** Use local `./scripts/gcp-deploy.sh` until the cluster works, then add GHA for `terraform validate` on PRs. Add full GHA deploy only if you want push-button redeploys without your laptop.

---

## Which is better?

| You want… | Use |
|-----------|-----|
| Deploy today on your laptop | `./scripts/gcp-deploy.sh` |
| Keep secrets off GitHub | Local scripts |
| Catch Terraform typos on PRs | GitHub Actions validate workflow |
| Deploy without your machine online | GitHub Actions + secrets (advanced) |

For this learning project: **start local, add GHA validate, skip full GHA deploy until you need it.**
