# Phase 4 Runbook — Failover (GCP)

Finish Layer 4 after Phase 1–2 (primary + standby + Velero). This runbook defines a
**finishable operator path**:

| Level | What you get | Automation |
|-------|----------------|------------|
| **A — Witness** | Cloud Function + Scheduler probe primary `/readyz`, Pub/Sub alerts, Workflow notify stub | Automated |
| **B — DNS failover** | Cloud DNS primary/backup A record (requires a domain) | Automated (HC) |
| **C — Apps on standby** | Scale Deployments (+ pause Argo sync). Velero **restore** still manual. | **Opt-in auto** via `enable_level_c_automation`, else `./scripts/failover-gcp.sh activate-apps` |

> **Honest boundary:** DNS/witness (A/B) are automated. Level C **scale** can be automated
> (Workflow → activate-apps CF). **Velero PVC restore** and **failback** stay operator-driven.

Design: [GCP-ARCHITECTURE.md](GCP-ARCHITECTURE.md)  
Interview demo (witness talk-track): [PORTFOLIO-DEMO.md](PORTFOLIO-DEMO.md)

---

## Prerequisites

1. Phase 1 + 2 applied; LB IPs and CP IPs present in Terraform state  
2. Velero on primary writing to the shared GCS bucket (Phase 2)  
3. APIs enabled (includes Gen2 Run/Cloud Build):

```bash
GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-enable-apis.sh
```

4. For witness reachability: primary `:6443` must accept Cloud Function egress. Lab option:

```hcl
# primary-cluster-gcp/terraform.tfvars
k3s_api_source_ranges = ["0.0.0.0/0"]
```

Then `terraform -chdir=primary-cluster-gcp apply`. Prefer locking this down later (VPC connector).

5. Optional domain registered at any registrar (needed only for DNS Level B)

---

## Step 1 — Shared services tfvars

```bash
cd shared-services-gcp
cp terraform.tfvars.example terraform.tfvars
```

Edit:

```hcl
gcp_project = "hybrid-k8s-dev"
enable_witness            = true
create_firestore_database = true   # false if project already has Firestore

# Level A only (no DNS yet):
domain_name = ""

# Level B (when ready):
# domain_name   = "example.com"
# app_subdomain = "app"
```

Confirm remote-state paths (defaults to sibling `../primary-cluster-gcp/terraform.tfstate` and `../cloud-services-gcp/terraform.tfstate`). Override LB/API if needed:

```hcl
# primary_lb_ip  = "x.x.x.x"
# standby_lb_ip  = "y.y.y.y"
# primary_api_url = "https://CP_NAT_IP:6443"
```

---

## Step 2 — Apply shared services

```bash
cd shared-services-gcp
terraform init
terraform apply
```

### Expect (domain empty)

- Firestore (if created)
- Pub/Sub topic
- Cloud Function Gen2 + Scheduler (1 min)
- Cloud Workflows failover (notify + stubs)

### Expect (domain set)

- Plus Cloud DNS managed zone + primary/backup A policy (TCP :443 health check)

---

## Step 3 — Domain NS (Level B only)

```bash
terraform -chdir=shared-services-gcp output dns_name_servers
```

At your registrar, set the domain’s nameservers to those values. Wait for delegation (`dig NS example.com`).

App hostname: `app.<domain>` (or `app_subdomain`).

---

## Step 4 — Verify witness (Level A)

```bash
# Logs
gcloud functions logs read hybrid-k8s-witness --region=us-central1 --gen2 --limit=20

# Firestore state
gcloud firestore documents describe witness/health --project=hybrid-k8s-dev || \
  echo "Use console: Firestore → witness/health"
```

Healthy primary → `consecutive_failures` resets to 0.  
After 3 failures → Workflow start + Pub/Sub message; `failover_active=true`.

**Failback (manual):** set Firestore `witness/health` to
`{"consecutive_failures": 0, "failover_active": false}` after primary is healthy again.

---

## Step 5 — App activation on standby (Level C)

DNS may already point at the standby LB after primary fails Cloud DNS health checks.
Standby GitOps overlays often set **replicas: 0** — something must scale them up.

### 5a — Manual (default)

```bash
./scripts/failover-gcp.sh status
./scripts/failover-gcp.sh activate-apps --dry-run

export STANDBY_KUBECONFIG=~/.kube/hybrid-standby.yaml
./scripts/failover-gcp.sh activate-apps
```

### 5b — Automated (opt-in)

When the witness fires, Cloud Workflows can call an **activate-apps** Cloud Function
that loads standby kubeconfig from Secret Manager, pauses Argo sync on known apps
(so `replicas: 0` overlays do not selfHeal), and scales `linkding` + `demo-app` to 1.

```bash
# 1) Seed kubeconfig (SSH to standby CP → Secret Manager)
GCP_PROJECT=hybrid-k8s-dev ./scripts/seed-standby-kubeconfig.sh

# 2) Lab: allow CF egress to standby :6443
# cloud-services-gcp/terraform.tfvars
#   k3s_api_source_ranges = ["0.0.0.0/0"]
terraform -chdir=cloud-services-gcp apply

# 3) Enable flag and apply shared-services
# shared-services-gcp/terraform.tfvars
#   enable_level_c_automation = true
terraform -chdir=shared-services-gcp apply

# 4) Confirm
./scripts/failover-gcp.sh status
# level_c_automation_enabled = true
```

**Drill:** stop/block primary API until witness threshold → check Workflow execution →
`kubectl get deploy -A` on standby shows replicas ≥ 1 → run `failback-notes`.

**Still not automated:** Velero restore (data), failback, Argo full sync policy restore.

---

## Step 6 — Deploy entrypoints

**GitHub Actions (preferred if secrets already set):**

```bash
# State must be in GCS first if you only ever applied locally:
# GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-tfstate-sync.sh push

gh workflow run gcp-phase4.yml -R dakaii/fantastic-spoon
# optional: -f domain_name=example.com -f app_subdomain=app
gh run watch -R dakaii/fantastic-spoon
```

**Local:**

```bash
./scripts/gcp-deploy.sh failover
```

`scripts/failover.sh` remains the **Cloudflare / portable** path — not Cloud DNS.

---

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| Witness always unhealthy | `k3s_api_source_ranges` / firewall; CP NAT IP in `PRIMARY_API_URL`; test `curl -k https://CP:6443/readyz` from an external host |
| Scheduler 403 | Gen2 needs `roles/run.invoker` + OIDC audience (fixed in TF) |
| Function build fails | Enable `run`, `cloudbuild`, `artifactregistry`, `secretmanager` via `gcp-enable-apis.sh` |
| DNS never flips | TCP HC on LB:443; Traefik up on primary; `primary_lb_ip` / `standby_lb_ip` correct |
| Level C activate 500 kubeconfig | Re-run `./scripts/seed-standby-kubeconfig.sh`; confirm secret versions |
| Level C timeout / connection | Standby `k3s_api_source_ranges` must allow CF egress (lab `0.0.0.0/0`) |
| Apps scale then go back to 0 | Argo selfHeal — activate pauses sync; re-check Applications |
| GHA cannot enable APIs | Re-run `./scripts/gcp-setup-github-actions.sh --full` (grants `serviceUsageAdmin`) |

---

## Done criteria (Phase 4 “finished”)

- [ ] Witness runs on schedule; Pub/Sub receives alerts on simulated outage  
- [ ] (Optional) `app.<domain>` fails over to standby LB when primary HC fails  
- [ ] Level C path practiced (manual **or** `enable_level_c_automation`)  
- [ ] Failback procedure documented and practiced once  

VPN cities remain a separate additive feature (`vpn-gateways-gcp`).
