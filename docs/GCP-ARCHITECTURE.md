# GCP Architecture — Locked Design

This document reflects the architecture for an **all-GCP, Terraform-managed, active-passive k3s platform with fully automated failover**.

GCP is the **default cloud provider** for this repo. AWS modules remain available as an alternative.

---

## Locked Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Cloud provider | **GCP** | Multi-project management under one account (e.g. daiki815@gmail.com) |
| IaC | **Terraform** (multi-project) | Separation of primary, standby, shared services |
| "Bare metal" emulation | **GCE instances directly** | No nested VMs — GCE *is* your bare-metal equivalent |
| Kubernetes | **k3s** (self-managed on GCE) | No GKE — saves managed cluster fees |
| GitOps | **Argo CD on both clusters** | Standby Argo CD pre-deployed for full automated failover |
| Failover | **Fully automated** | Cloud Function witness + Cloud DNS + Velero + standby Argo CD |
| DNS | **Cloud DNS** (requires a domain) | Native GCP integration with health-checked failover routing |
| Backups | **Velero → GCS** | Cross-cluster restore on failover (HMAC keys, S3-compatible API) |

---

## GCE vs Nested Virtualization

**You do not need QEMU on GCP.** GCE VMs with cloud-init + Ansible mirror bare-metal provisioning:

```
Terraform apply
  → GCE instances launch
    → cloud-init injects SSH keys, hostname, packages
      → Ansible installs k3s, Cilium, Longhorn, Traefik
        → Argo CD deploys apps from Git
```

---

## Architecture Diagram

```
                         ┌─────────────────────────────────────┐
                         │           Cloud DNS                      │
                         │  app.yourdomain.com                   │
                         │  (primary/backup routing policy)      │
                         └──────────┬──────────────┬─────────────┘
                                    │              │
                          PRIMARY (healthy)    STANDBY (on failure)
                                    │              │
┌───────────────────────────────────▼──┐  ┌───────▼──────────────────────────┐
│  PRIMARY CLUSTER (multi-zone)        │  │  STANDBY CLUSTER (single zone)   │
│                                      │  │                                  │
│  ┌─────────┐ ┌─────────┐ ┌────────┐ │  │  ┌─────────┐ ┌─────────┐        │
│  │ CP-1    │ │ CP-2    │ │ CP-3   │ │  │  │ SB-1    │ │ SB-2    │        │
│  │e2-small │ │e2-small │ │e2-small│ │  │  │e2-micro │ │e2-micro │        │
│  └────┬────┘ └────┬────┘ └────┬───┘ │  │  └────┬────┘ └────┬────┘        │
│       └───────────┴───────────┘      │  │       └───────────┘               │
│              k3s HA (embedded etcd)  │  │         k3s (standby)             │
│                                      │  │                                  │
│  Argo CD (primary) ── watches Git    │  │  Argo CD (standby) ── watches Git│
│  Traefik (active ingress)            │  │  Traefik (idle until failover)   │
│  Longhorn, Cilium, Prometheus        │  │  Cilium, Prometheus              │
│  Apps running (replicas > 0)         │  │  Apps synced (replicas = 0)      │
└──────────────────┬───────────────────┘  └──────────────┬───────────────────┘
                   │                                       │
                   └──────────── Velero backups ───────────┘
                                        │
                              ┌─────────▼─────────┐
                              │  GCS Backup Bucket │
                              └───────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  SHARED SERVICES (shared-services-gcp/)                                       │
│                                                                             │
│  Cloud Function witness (Cloud Scheduler, every 1 min)                      │
│    → checks primary k3s API /readyz                                         │
│    → on 3 failures: trigger Cloud Workflows failover                        │
│                                                                             │
│  Cloud Workflows Failover:                                                  │
│    1. Confirm primary is down                                               │
│    2. Velero restore latest backup to standby                               │
│    3. Scale standby app replicas 0 → N (patch Git or Argo CD apps)          │
│    4. Cloud DNS primary/backup record → standby LB IP                       │
│    5. Pub/Sub notification                                                  │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## AWS → GCP Service Mapping

| AWS | GCP |
|-----|-----|
| EC2 t4g.small | GCE e2-small |
| EC2 t4g.micro (standby) | GCE e2-micro (free tier eligible) |
| S3 | GCS |
| Lambda witness | Cloud Function (Gen2) |
| Step Functions | Cloud Workflows |
| Route53 failover | Cloud DNS primary/backup routing |
| NLB | External TCP forwarding rule + regional backend service |
| IAM + Velero keys | Service account + GCS HMAC keys |
| DynamoDB witness state | Firestore |
| SNS alerts | Pub/Sub |

---

## Terraform Project Structure

```
├── primary-cluster-gcp/      # Project 1: GCE nodes for primary k3s HA
├── cloud-services-gcp/       # Project 2: GCE standby + GCS + HMAC keys
├── shared-services-gcp/    # Project 3: Cloud DNS, witness, Workflows
├── primary-cluster/          # AWS alternative (unchanged)
├── cloud-services/           # AWS alternative (unchanged)
├── shared-services/          # AWS alternative (unchanged)
├── ansible/                  # Bootstraps both clusters (provider-agnostic)
├── gitops/                   # Argo CD manifests (both clusters)
└── docs/
```

Apply order: `primary-cluster-gcp` → `cloud-services-gcp` → Ansible → `shared-services-gcp` (needs domain for Cloud DNS).

---

## GCP Account Setup

1. Sign in at [console.cloud.google.com](https://console.cloud.google.com) with your Google account
2. Create a project (e.g. `hybrid-k8s-dev`) — repeat for staging/prod as needed
3. Link billing (free tier covers 1× e2-micro in US regions)
4. Authenticate Terraform:
   ```bash
   gcloud auth application-default login
   gcloud config set project YOUR_PROJECT_ID
   ```
5. Enable APIs (or let Terraform fail with a clear error and enable manually):
   ```bash
   gcloud services enable compute.googleapis.com storage.googleapis.com \
     dns.googleapis.com cloudfunctions.googleapis.com cloudscheduler.googleapis.com \
     workflows.googleapis.com firestore.googleapis.com pubsub.googleapis.com \
     --project=YOUR_PROJECT_ID
   ```

---

## Instance Sizing (GCP)

### Primary Cluster (dev)

| Node | Role | Type | ~$/mo |
|------|------|------|-------|
| cp-1 | k3s server | e2-small | ~$12 |
| w-1, w-2 | k3s agent | e2-small | ~$24 |
| **Subtotal** | | | **~$36** |

### Standby Cluster

| Node | Role | Type | ~$/mo |
|------|------|------|-------|
| sb-1, sb-2 | server + agent | e2-micro | ~$0–12 (1 free tier) |
| GCS backups | 100 GB | Standard | ~$2 |
| **Subtotal** | | | **~$2–14** |

### Shared Services

| Service | ~$/mo |
|---------|-------|
| Cloud Function + Scheduler | ~$0 |
| Cloud DNS zone + health check | ~$1 |
| Firestore / Pub/Sub | ~$0 |
| **Subtotal** | **~$1** |

### Total (dev)

| Config | ~$/mo |
|--------|-------|
| Primary + standby + shared | ~$39–51 |

---

## Domain — Do You Need One?

**Yes, for fully automated DNS failover in Phase 4.**

Until then, use the TCP load balancer IP directly:

```bash
terraform -chdir=primary-cluster-gcp output primary_lb_ip
```

Register a domain at Google Domains, Cloudflare, or any registrar, then point NS to Cloud DNS name servers from `shared-services-gcp` output.

---

## Implementation Phases

| Phase | What | Domain needed? |
|-------|------|----------------|
| 1 | Primary GCE + k3s via Terraform/Ansible | No |
| 2 | Standby GCE + Velero GCS backups | No |
| 3 | Dual Argo CD + GitOps sync (Linkding) | No |
| 4 | Cloud Function witness + Workflows + Cloud DNS | **Yes** |

---

## Quick Start

```bash
cp config/clusters.example.yaml config/clusters.yaml
cp primary-cluster-gcp/terraform.tfvars.example primary-cluster-gcp/terraform.tfvars
cp cloud-services-gcp/terraform.tfvars.example cloud-services-gcp/terraform.tfvars

chmod +x scripts/*.sh
./scripts/phase1-primary.sh    # or provision.sh + bootstrap-cluster.sh primary
./scripts/phase2-standby.sh  # standby + GCS

# Phase 4 (after domain):
cp shared-services-gcp/terraform.tfvars.example shared-services-gcp/terraform.tfvars
cd shared-services-gcp && terraform apply
```

See also [GCP Compute provisioner](../provisioners/gcp-compute/README.md) and [AWS Architecture](AWS-ARCHITECTURE.md) for the alternative cloud path.
