# Phase 4 Runbook — Automated Failover (GCP)

Finish Layer 4 after Phase 1–2 (primary + standby + Velero). This runbook defines a
**finishable operator path**:

| Level | What you get |
|-------|----------------|
| **A — Witness** | Cloud Function + Scheduler probe primary `/readyz`, Pub/Sub alerts, Workflow notify stub |
| **B — DNS failover** | Cloud DNS primary/backup A record (requires a domain) |
| **C — Apps on standby** | **Manual** Velero restore + scale/sync (Workflow Velero/Argo steps are placeholders) |

Full Velero/Argo automation inside Cloud Workflows is **out of scope for this finish** — same as the AWS Step Functions stub.

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

## Step 5 — Manual app activation on standby (Level C)

DNS may already point at the standby LB after primary fails Cloud DNS health checks.
Standby workloads often start at **0 replicas** — activate them:

```bash
# Prefer the helper (reads standby inventory / kubeconfig you supply):
export STANDBY_KUBECONFIG=~/.kube/hybrid-standby.yaml
./scripts/failover-gcp.sh activate-apps

# Or manually:
# - Restore latest Velero backup onto standby (if using Velero across clusters)
# - kubectl -n linkding scale deploy/linkding --replicas=1
# - Sync Argo apps on standby
```

There is **no** automated failback Workflow yet — reverse DNS/apps manually when primary is healthy (`./scripts/failover-gcp.sh failback-notes`).

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
| Function build fails | Enable `run`, `cloudbuild`, `artifactregistry` via `gcp-enable-apis.sh` |
| DNS never flips | TCP HC on LB:443; Traefik up on primary; `primary_lb_ip` / `standby_lb_ip` correct |
| GHA cannot enable APIs | Re-run `./scripts/gcp-setup-github-actions.sh --full` (grants `serviceUsageAdmin`) |

---

## Done criteria (Phase 4 “finished”)

- [ ] Witness runs on schedule; Pub/Sub receives alerts on simulated outage  
- [ ] (Optional) `app.<domain>` fails over to standby LB when primary HC fails  
- [ ] Documented/manual path activates apps on standby  
- [ ] Failback procedure documented and practiced once  

Then you may merge/run **VPN V1** (`vpn-gateways-gcp`) as a separate additive feature (single city is enough).
