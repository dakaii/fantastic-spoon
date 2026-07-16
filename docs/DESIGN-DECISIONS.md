# Design Decisions — Hybrid Bare-Metal Kubernetes Platform

This document captures the key architectural decisions, cloud provider trade-offs, and recommended defaults for building the platform properly.

---

## 1. Is AWS More Expensive Than Azure and GCP?

**Short answer: It depends on the service, but for *this* project GCP is often the cheapest — and can be $0 for a single standby node.**

There is no universal "AWS is most expensive" rule. Each provider wins different categories:

| Category | Typical winner | Notes |
|----------|---------------|-------|
| Smallest always-on VM | **GCP** (e2-micro) | Permanently free in `us-central1`, `us-east1`, `us-west1` |
| Smallest paid ARM VM | **AWS** (t4g.nano) | ~$3/mo in us-east-1, but only 512 MB RAM — too small for k3s |
| Practical k3s standby node (1 GB RAM) | **GCP free** or **AWS t4g.micro** (~$6/mo) | Tie depending on free tier eligibility |
| Small burstable VM (paid) | **AWS ≈ GCP < Azure** | Azure B1s ~$7.60/mo vs GCP e2-micro ~$6/mo vs AWS t4g.micro ~$6/mo |
| Object storage (100 GB) | **Azure ≈ GCP < AWS** | ~$1.80–2.30/mo; differences are small at this scale |
| Serverless witness (Lambda/Functions) | **All ~$0** | Free tiers cover a 1-min health check easily |
| Egress to internet | **AWS ≈ Azure < GCP** | GCP egress is often higher ($0.12/GB vs ~$0.09/GB) |
| Managed Kubernetes (EKS/AKS/GKE) | N/A for this project | We use k3s, not managed K8s — saves $70–150/mo per cluster |

### Standby Node Pricing (1 GB RAM, on-demand, US region)

| Provider | Instance | vCPU | RAM | ~$/month | Free tier? |
|----------|----------|------|-----|----------|------------|
| AWS | t4g.micro | 2 | 1 GB | ~$6 | 12 months (t2/t3.micro) |
| AWS | t4g.nano | 2 | 0.5 GB | ~$3 | Too small for k3s |
| GCP | e2-micro | 2 (shared) | 1 GB | **$0** | **Always free** (1 VM, qualifying regions) |
| Azure | B1s | 1 | 1 GB | ~$7.60 | 12 months |

### Object Storage (100 GB/month, standard tier)

| Provider | Service | ~$/month |
|----------|---------|----------|
| AWS | S3 Standard | ~$2.30 |
| GCP | Cloud Storage Standard | ~$2.00 |
| Azure | Blob Hot | ~$1.80 |

### Total Monthly Cost for This Architecture

| Design | AWS | GCP | Azure |
|--------|-----|-----|-------|
| 1 standby node + backups + witness | ~$8–10 | **~$2–3** (1 free VM) | ~$10–12 |
| 2 standby nodes + backups + witness | ~$14–16 | ~$8–10 (1 free + 1 paid) | ~$18–20 |

**Recommendation for cost-sensitive learning:** Start with **GCP** — one free e2-micro standby node, Cloud Storage for Velero backups, and a Cloud Function as witness. Add a second paid node only when you need HA for the standby cluster itself.

**Recommendation if you already know AWS:** Stay on AWS. The ~$5–10/mo difference is negligible compared to learning friction, and the starter Terraform in this repo already targets AWS.

---

## 2. Core Design Decisions

### Decision 1: Simulated Bare Metal vs. Real Hardware

| Option | When to choose |
|--------|---------------|
| **QEMU/libvirt VMs** (default) | Learning, no extra hardware, reproducible |
| **Raspberry Pi fleet** | Want real ARM edge experience; have hardware |
| **Mac Mini** | Powerful local nodes; good k3s control plane |
| **Mix** | Pi for workers, VM/Mac for control plane |

**Recommendation:** Start with QEMU/libvirt. Swap to real hardware later without changing GitOps or cloud layers.

### Decision 2: k3s vs. Full Kubernetes (kubeadm/RKE2)

| | k3s | kubeadm / RKE2 |
|---|-----|----------------|
| RAM per node | ~512 MB minimum | ~2 GB minimum |
| HA setup | Embedded etcd, simple | External etcd, complex |
| Production use | Widely used at edge | Enterprise standard |
| Fit for Pi / nano VMs | Excellent | Poor on tiny instances |

**Recommendation:** k3s everywhere (local primary and cloud standby).

### Decision 3: One Cloud Provider vs. Multi-Cloud Standby

| Option | Pros | Cons |
|--------|------|------|
| **Single cloud** | Simple, one Terraform project, one billing account | Provider outage = no standby |
| **Multi-cloud standby** | Maximum resilience | 2× complexity, 2× cost, harder GitOps |

**Recommendation:** Single cloud for v1. Multi-cloud is a v2 enhancement.

### Decision 4: Standby Cluster Size

| Size | Cost | Recovery speed | When |
|------|------|---------------|------|
| **0 nodes (backup only)** | ~$2–3/mo | 30–60 min manual restore | Learning Phase 1–2 |
| **1 node (cold/warm)** | ~$3–8/mo | 10–20 min | Recommended starting point |
| **2 nodes (warm HA)** | ~$10–16/mo | 5–10 min | When you test failover regularly |
| **3 nodes (full HA)** | ~$18–25/mo | 1–5 min | Production-like requirements |

**Recommendation:** Phase 1 with backup-only (no standby VMs). Phase 2 add 1 standby node. Phase 3 add second node + automated failover.

### Decision 5: GitOps — Argo CD vs. Flux

| | Argo CD | Flux |
|---|---------|------|
| UI | Built-in web UI | No built-in UI (Weave GitOps optional) |
| Multi-cluster | Native cluster secrets + ApplicationSets | Flux ClusterConfig / multi-tenancy |
| Failover integration | Patch Application destination (simple) | Patch Kustomization/HelmRelease target |
| Community / adoption | Very large | Very large (CNCF graduated) |
| Learning curve | Moderate | Moderate |

**Recommendation:** Argo CD — better visibility for learning, and the failover script pattern (patch destination + sync) is straightforward.

### Decision 6: Where Argo CD Lives

| Option | Pros | Cons |
|--------|------|------|
| **On local primary** (recommended) | Free, low latency to main cluster | If local dies completely, you lose the GitOps controller |
| **On cloud standby** | Survives local failure | Costs money always; local is primary 99% of the time |
| **Both (Argo CD + agent model)** | Resilient | Over-engineered for v1 |

**Recommendation:** Argo CD on local primary. During failover, the witness script patches Application destinations *before* local is fully dead (API may still be reachable during partial failure), or you pre-register a second Argo CD instance on standby that takes over.

**Important nuance:** If the local cluster is completely dead (not just unhealthy), you cannot patch Argo CD on it. Mitigation options:

1. **Pre-deploy Argo CD on standby** in read-only/disabled mode — witness activates it during failover.
2. **Run Argo CD on a tiny cloud VM** outside both clusters (always-on, ~$3–6/mo).
3. **Accept semi-automated failover** — witness restores Velero + updates DNS; you manually sync apps on standby.

For v1 learning, option 3 is fine. For full automation, option 1 or 2.

### Decision 7: DNS Provider

| Option | Cost | Failover mechanism |
|--------|------|-------------------|
| **Cloudflare** (recommended) | Free | API-driven A record swap (TTL 60s) |
| Route53 | ~$0.50/zone + queries | Health checks + failover routing (~$1/health check) |
| GCP Cloud DNS | ~$0.20/zone | Manual or scripted record update |

**Recommendation:** Cloudflare free tier — simple API, fast propagation, no per-health-check fees.

### Decision 8: Backup Strategy

| Layer | Tool | Frequency | Retention |
|-------|------|-----------|-----------|
| etcd + cluster resources | Velero | Every 6 hours | 30 days |
| etcd snapshot (k3s native) | k3s etcd-snapshot | Hourly | 7 days |
| Persistent volumes | Velero + Restic | With full backup | 30 days |
| GitOps state | Git repo | Every commit | Forever |

**Recommendation:** Velero to cloud object storage as primary; k3s native snapshots as secondary.

### Decision 9: Witness / Failover Controller

| Option | Cost | Reliability |
|--------|------|-------------|
| **Cloud Function / Lambda** (recommended) | ~$0 | Good; runs even if both clusters are down |
| CronJob on cloud standby | $0 (uses existing node) | Bad; if standby is down, no detection |
| CronJob on local | $0 | Bad; if local is down, no detection |
| Dedicated tiny VM | ~$3–6/mo | Best isolation |

**Recommendation:** Lambda (AWS) or Cloud Function (GCP) on a 1-minute schedule calling `health-check.sh` logic.

---

## 3. Recommended Architecture (Phased)

### Phase 1 — Local Only (~$0/mo cloud)

```
Your laptop/workstation
├── Terraform (libvirt) → 3–5 QEMU VMs
├── Ansible → k3s HA cluster
├── Helm → Cilium, Longhorn, Traefik, Prometheus
└── Manual kubectl deploys (no GitOps yet)
```

**Goal:** Working local k3s cluster. Understand provisioning flow.

### Phase 2 — Backups to Cloud (~$2–3/mo)

```
Local k3s ──Velero──► Cloud Storage (S3/GCS/Blob)
```

**Goal:** Disaster recovery via restore. Pick your cloud provider here.

### Phase 3 — GitOps + Standby (~$5–12/mo)

```
Local k3s (Argo CD) ──sync──► Git repo
Cloud standby (1 node) ◄── Argo CD (registered cluster)
Witness (Lambda/Function) ──monitors──► Local API
```

**Goal:** Declarative deployments. Standby cluster exists but receives no traffic.

### Phase 4 — Automated Failover (~$10–25/mo)

```
Witness detects failure
  → Velero restore to standby
  → Patch Argo CD destinations (or activate standby Argo CD)
  → Cloudflare DNS swap
  → Slack notification
```

**Goal:** End-to-end automated failover in under 10 minutes.

---

## 4. Provider-Specific Recommendations

### If you choose GCP (cheapest for learning)

| Component | GCP service | Config |
|-----------|------------|--------|
| Standby node | e2-micro (free tier) | 1 VM in us-central1 |
| Backups | Cloud Storage | Standard bucket, 100 GB |
| Witness | Cloud Function (Gen 2) | 1-min Cloud Scheduler trigger |
| Secrets | Secret Manager | Velero credentials |
| DNS | Cloudflare (external) | Free tier |
| Terraform | google provider | `cloud-services-gcp/` (to be created) |

### If you choose AWS (already in this repo)

| Component | AWS service | Config |
|-----------|------------|--------|
| Standby nodes | EC2 t4g.micro (×1–2) | ARM, us-east-1 |
| Backups | S3 | Standard bucket, lifecycle 30 days |
| Witness | Lambda + EventBridge | 1-min schedule |
| Secrets | Secrets Manager | Velero credentials |
| DNS | Cloudflare (external) | Free tier |
| Terraform | aws provider | `cloud-services/` (existing) |

### If you choose Azure

| Component | Azure service | Config |
|-----------|------------|--------|
| Standby node | B1s (free tier 12 mo) | 1 VM, East US |
| Backups | Blob Storage | Hot tier |
| Witness | Azure Functions | Timer trigger |
| Secrets | Key Vault | Velero credentials |
| DNS | Cloudflare (external) | Free tier |
| Terraform | azurerm provider | `cloud-services-azure/` (to be created) |

---

## 5. What NOT to Do (Common Mistakes)

1. **Don't run managed Kubernetes (EKS/GKE/AKS)** for the standby — k3s on a $6 VM does the same job for learning at 10× lower cost.
2. **Don't start with full automated failover** — get local cluster + backups working first.
3. **Don't use t4g.nano (512 MB)** for k3s — it will OOM. Minimum 1 GB RAM.
4. **Don't put Argo CD only on the cluster that might die** — plan for the controller surviving local failure.
5. **Don't multi-cloud in v1** — pick one provider, learn it deeply.
6. **Don't skip restore testing** — a backup you've never restored is not a backup.

---

## 6. Decision Summary

| Decision | Recommended choice |
|----------|--------------------|
| Cloud provider (cost) | **GCP** (free e2-micro) |
| Cloud provider (existing repo) | **AWS** (starter Terraform included) |
| Local provisioning | QEMU/libvirt + cloud-init + Ansible |
| Kubernetes | k3s (local + standby) |
| GitOps | Argo CD on local primary |
| Ingress | Traefik (ops/apps — not consumer VPN egress) |
| Consumer VPN | WireGuard full-tunnel city exits (`vpn-gateways-gcp/`) |
| Storage | Longhorn (local), cloud object storage (backups) |
| CNI | Cilium |
| Backup | Velero → cloud object storage |
| DNS / failover | Cloudflare (free) |
| Witness | Lambda or Cloud Function (~$0) |
| Standby size | 1 node (Phase 3), 2 nodes (Phase 4) |
| Monthly budget | $0 → $3 → $10 → $25 as phases progress |

---

## 7. Open Questions (Decide Before Building)

1. **Which cloud provider do you already have an account with?** (Reduces learning friction)
2. **Do you have a domain name for DNS failover testing?** (Cloudflare needs a real domain)
3. **What machine will run the QEMU VMs?** (Needs 16+ GB RAM, KVM support)
4. **Do you want ARM experience (Pi) or x86 is fine?** (Affects VM image and cloud instance type)
5. **Is fully automated failover a v1 requirement, or acceptable as Phase 4?**

---

*Update this document as you make decisions during implementation.*
