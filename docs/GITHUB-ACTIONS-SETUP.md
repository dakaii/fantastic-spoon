# GitHub Actions setup (GCP)

Run deploy and destroy from GitHub’s cloud so you can close your laptop. Works on a **public repo** when secrets stay in GitHub Secrets (never commit keys).

**GCP project creation is not in GitHub Actions** — create the project once manually (Console or local script), then use Actions for deploy/destroy.

---

## Workflows

| Workflow | When to use |
|----------|-------------|
| **GCP Bootstrap** | Ansible/k3s only — VMs already exist, need (re)bootstrap |
| **GCP Phase 2** | Standby Terraform + bootstrap + Velero on primary (after Phase 1) |
| **GCP Phase 4** | Witness + optional Cloud DNS (`shared-services-gcp`) |
| **GCP VPN** | WireGuard gateway VM + client `.conf` artifact (single city) |
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

# Deploy + Destroy + Phase 4 shared-services (Compute/Storage/DNS/Functions/...):
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-setup-github-actions.sh --full --push-secrets
# --full now also grants serviceUsageAdmin + Phase 4 roles (DNS, Functions, Run, Workflows, …)
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

### Phase 2 (standby + GCS + Velero) — no local login

Requires **full** service account (`--full` flag when running setup). Same secrets as Deploy All.

Actions → **GCP Phase 2** → Run workflow

```bash
gh workflow run gcp-phase2.yml -R dakaii/fantastic-spoon
gh run watch -R dakaii/fantastic-spoon
```

This runs: `cloud-services-gcp` Terraform → bootstrap standby → configure Velero on primary.

**Bootstrap-only alternative** (if standby VMs already exist from a prior Terraform apply):

```bash
gh workflow run gcp-bootstrap.yml -f cluster=standby -R dakaii/fantastic-spoon
```

### Phase 4 (failover witness + optional DNS) — no local login

Requires **full** SA (`--full`) and **primary + standby Terraform state in GCS**
(`./scripts/gcp-tfstate-sync.sh push` if you only applied locally before).

```bash
# Witness only (no domain):
gh workflow run gcp-phase4.yml -R dakaii/fantastic-spoon

# With Cloud DNS (after you own a domain):
gh workflow run gcp-phase4.yml -R dakaii/fantastic-spoon \
  -f domain_name=example.com -f app_subdomain=app

gh run watch -R dakaii/fantastic-spoon
```

Then follow [PHASE-4-RUNBOOK.md](PHASE-4-RUNBOOK.md) for NS delegation and
`./scripts/failover-gcp.sh` (app activation still manual / local kubeconfig).

### VPN V1 (WireGuard city gateway) — no local login

**Deploy:**

```bash
gh workflow run gcp-vpn.yml -R dakaii/fantastic-spoon -f city=us
gh run watch -R dakaii/fantastic-spoon
```

Download the **wireguard-client-us** artifact, copy `laptop-us.conf` to
`vpn-clients/us/`, then connect with CLI:

```bash
./scripts/vpn.sh up
./scripts/vpn.sh ip
./scripts/vpn.sh down
```

See [VPN-RUNBOOK.md](VPN-RUNBOOK.md).

**Destroy VPN only** (keeps primary/standby):

```bash
gh workflow run gcp-vpn-destroy.yml -R dakaii/fantastic-spoon
gh run watch -R dakaii/fantastic-spoon
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

Full write-up of failures from primary/standby bring-up (with run IDs and PRs):
[GCP-BOOTSTRAP-ISSUES.md](GCP-BOOTSTRAP-ISSUES.md).

| Problem | Fix |
|---------|-----|
| SSH timeout | `admin_cidr` stale — update tfvars + `terraform apply` (dev: temp `0.0.0.0/0`) |
| Deploy tries to recreate VMs | Run `./scripts/gcp-tfstate-sync.sh push` from Mac first |
| Destroy does nothing | Same — state must be in GCS bucket |
| Ansible fails | Re-run **GCP Bootstrap** (idempotent) after clearing stuck Helm if needed |
| Argo CD `failed pre-install` / stuck Helm | Skip redis hook + cleanup release secrets — see issues log §8–9. Manual: `helm uninstall argocd -n argocd` then delete `sh.helm.release.v1.argocd*` |
| NodePort `30080` already allocated | Argo CD uses `32080`/`32443` (not Traefik’s range) |
| Velero `spec.provider: Required` | Skip until GCS bucket + HMAC from Phase 2 exist |
| Traefik/Helm `INTERNAL_ERROR` or apt hung for hours | Standby was **e2-micro** — resize to **e2-small+** then re-bootstrap |
| Cilium TLS / `certificate is valid for ... not <new-ip>` | Ephemeral GCP IP changed — Cilium must use **internal** API IP (`10.1.0.4`), not external NAT IP. Reinstall Cilium with `k8sServiceHost=10.1.0.4` (see docs) |
| `kubectl` / API timeouts on control plane | Control plane OOM on `e2-small` — resize to `e2-medium` (see below) |
| Phase 2 `Permission denied to enable service` | Owner must enable APIs / grant SA — GHA SA alone often cannot |
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
