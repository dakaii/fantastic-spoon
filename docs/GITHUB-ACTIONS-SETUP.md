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
| **GCP VPN Destroy** | Tear down VPN gateway only (primary/standby untouched) |
| **GCP Deploy All** | Full stack: Terraform + bootstrap + Linkding apps (`skip_apps` to skip apps) |
| **GCP Destroy** | Tear down all resources (`terraform destroy`) |
| **Terraform Validate** | Automatic on PRs — no secrets |
| **Shellcheck** | Automatic on PRs — lints `scripts/*.sh` |

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
# --full grants: Compute/Storage admin, storage.hmacKeyAdmin (Velero HMAC destroy),
# serviceUsageAdmin, Phase 4 roles (DNS, Functions, Run, Workflows, …)
# Re-run with --full anytime to add missing roles to an existing github-actions SA.
```

| Secret | Required for |
|--------|----------------|
| `GCP_PROJECT` | All |
| `GCP_SA_KEY` | All |
| `SSH_PRIVATE_KEY` | Bootstrap, Deploy |
| `SSH_PUBLIC_KEY` | Deploy, Destroy |
| `ADMIN_CIDR` | Deploy — your IP `/32` preferred; lab/GHA runners may need temporary `0.0.0.0/0` (explicit) |
| `GRAFANA_ADMIN_PASSWORD` | Optional — primary bootstrap; if unset, bootstrap generates one (masked in Actions) |

### 3. Seed Terraform state (if you already deployed locally)

So Deploy/Destroy know what exists:

```bash
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-tfstate-sync.sh push
```

State is stored in `gs://YOUR_PROJECT-tfstate/`.

### 4. SSH firewall for GitHub runners

GitHub-hosted runners use **dynamic** egress IPs. Pick one:

**A) Lab only (temporary open SSH)** — then tighten after bootstrap:

```hcl
admin_cidr = "0.0.0.0/0"   # temporary — do not leave forever
```

```bash
cd primary-cluster-gcp && terraform apply
```

When `admin_cidr` is world-open, **do not** leave VPN metrics on the same allowlist: VPN deploy auto-sets `vpn_metrics_cidrs` to primary NAT `/32`s.

**B) Locked down** — `admin_cidr = "YOUR.IP/32"` and bootstrap from that machine (`./scripts/bootstrap-cluster.sh`), not from GitHub-hosted runners.

### 5. Protect destroy with a GitHub Environment (required by workflows)

**GCP Destroy** and **GCP VPN Destroy** use `environment: gcp-destroy`. Create it once:

1. Repo **Settings → Environments → New environment** → name: `gcp-destroy`
2. Enable **Required reviewers** → add yourself
3. Save

Until the environment exists (and after it requires review), destroy runs wait for approval in the Actions UI. `gh workflow run` still queues the run; approve in the browser.

---

## Run from GitHub or CLI

### Bootstrap only (your current situation)

**Run one workflow at a time.** Two concurrent bootstrap runs will fight over Helm and leave releases stuck (`another operation is in progress`).

```bash
gh workflow run gcp-bootstrap.yml -f cluster=primary -R dakaii/fantastic-spoon
gh run watch -R dakaii/fantastic-spoon
```

Optional Grafana password (otherwise generated + masked):

```bash
gh secret set GRAFANA_ADMIN_PASSWORD -b 'your-long-password' -R dakaii/fantastic-spoon
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

#### After VPN deploy — monitoring (usually automatic)

`gcp-vpn.yml` / `./scripts/gcp-deploy.sh vpn` now run `./scripts/vpn-monitoring-wire.sh`:

1. Discover primary node NAT IPs → set `vpn_metrics_cidrs` (avoids inheriting `0.0.0.0/0`)
2. Generate scrape values (`tmp/vpn-additional-scrape.yaml`)
3. Helm-upgrade kube-prometheus-stack + apply GitOps VPN rules/dashboard (when primary kubeconfig/SSH works)

Manual re-wire anytime:

```bash
./scripts/vpn-monitoring-wire.sh
```

If primary was down during VPN deploy, re-run the wire script after bootstrap. Artifact
`vpn-prometheus-scrape-<city>` is also uploaded from GHA.

### Full deploy (greenfield or re-deploy)

Actions → **GCP Deploy All** → Run workflow

```bash
gh workflow run gcp-deploy-all.yml -R dakaii/fantastic-spoon
```

### Destroy everything (stop billing)

**Recommended (one command):** pushes local Terraform state, checks that ADC matches
your `gcloud` account, then destroys.

```bash
# Local destroy (uses your Mac + ADC — best when you applied TF locally)
GCP_PROJECT=hybrid-k8s-dev GCP_ACCOUNT=you@gmail.com ./scripts/gcp-teardown.sh

# Or GitHub Actions (push state first, then workflow with pre/post VM checks)
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-teardown.sh --gha --watch
```

**GCP Destroy** workflow now:
1. Fails early if VMs exist but GCS has no Terraform state (push state first)
2. Runs `terraform destroy` for all modules (fails the job on module errors)
3. Fails if any compute instances remain afterward

Actions → **GCP Destroy** → Run workflow still works if state is already in GCS:

```bash
gh workflow run gcp-destroy.yml -R dakaii/fantastic-spoon
```

Optional: check **delete_project** to remove the GCP project too.

Destroy workflows require Environment **`gcp-destroy`** with reviewers (see §5 above). Without it, the job fails or waits for approval.

**Why destroy used to “succeed” but leave VMs:** (1) local state never pushed to GCS,
(2) `gcloud` account ≠ Application Default Credentials (Terraform uses ADC),
(3) missing `roles/storage.hmacKeyAdmin` on the GHA SA. `gcp-teardown.sh` covers (1)+(2);
re-run `./scripts/gcp-setup-github-actions.sh --full` for (3).

---

## Why no “create project” workflow?

Creating a GCP project requires **org/folder Project Creator** and **Billing Account User** permissions. A service account inside one project usually cannot create sibling projects. Create the project once manually, then automate deploy/destroy.

---

## Public repo safety

- Secrets only in GitHub Secrets — never in git
- Workflows are manual (`workflow_dispatch`) only
- Use a dedicated deploy SSH key + service account
- **GCP Destroy** / **GCP VPN Destroy** require Environment `gcp-destroy` approval
- Prefer `admin_cidr` = your IP `/32`; treat `0.0.0.0/0` as lab-only and temporary
- Grafana password via `GRAFANA_ADMIN_PASSWORD` (or generated at bootstrap — not `changeme` in git)

---

## Troubleshooting

Full write-up of failures from primary/standby bring-up (with run IDs and PRs):
[GCP-BOOTSTRAP-ISSUES.md](GCP-BOOTSTRAP-ISSUES.md).

| Problem | Fix |
|---------|-----|
| SSH timeout | `admin_cidr` stale — update tfvars + `terraform apply` (lab: temporary `0.0.0.0/0`, then tighten) |
| Deploy tries to recreate VMs | Run `./scripts/gcp-tfstate-sync.sh push` from Mac first |
| Destroy does nothing | Same — state must be in GCS bucket (`./scripts/gcp-teardown.sh` pushes first) |
| Destroy “success” but standby left / HMAC 403 | Re-run setup with `--full` (needs `roles/storage.hmacKeyAdmin`); workflow now fails the job if any module destroy errors |
| Terraform 403 as wrong email | `gcloud` ≠ ADC — `gcloud auth application-default login` as the project owner; or use `./scripts/gcp-teardown.sh` which checks |
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

# After start, pick the CP public IP from:
#   terraform -chdir=primary-cluster-gcp output -json primary_control_plane_ips
ssh ubuntu@CONTROL_PLANE_PUBLIC_IP \
  "sudo systemctl restart k3s && sleep 60 && sudo k3s kubectl get nodes"
```

Or change `control_plane_machine_type` in local `terraform.tfvars` and `terraform apply` (instance must be stopped).
