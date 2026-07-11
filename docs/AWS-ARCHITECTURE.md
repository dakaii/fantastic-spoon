# AWS Architecture — Locked Design

This document reflects the final architecture decisions for an **all-AWS, Terraform-managed, active-passive k3s platform with fully automated failover**.

---

## Locked Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Cloud provider | **AWS** | User preference; starter Terraform already exists |
| IaC | **Terraform** (multi-project) | Separation of primary, standby, shared services |
| "Bare metal" emulation | **EC2 instances directly** | No QEMU on AWS — EC2 *is* your bare-metal equivalent |
| Kubernetes | **k3s** (self-managed on EC2) | No EKS — saves ~$73/mo per cluster |
| GitOps | **Argo CD on both clusters** | Standby Argo CD pre-deployed for full automated failover |
| Failover | **Fully automated** | Lambda witness + Route53 + Velero + standby Argo CD |
| DNS | **Route53** (requires a domain) | Native AWS integration with health checks |
| Backups | **Velero → S3** | Cross-cluster restore on failover |

---

## EC2 vs QEMU on AWS — Important Clarification

**You do not need QEMU on AWS.** Here is the distinction:

| Approach | What it is | When to use |
|----------|-----------|-------------|
| **EC2 instances (recommended)** | Terraform provisions EC2 → cloud-init bootstraps → Ansible installs k3s | Emulating bare-metal provisioning in AWS. You own the OS, no managed K8s. |
| **QEMU/libvirt (local laptop)** | VMs on your machine simulating physical servers | Free local compute; original design for homelab |
| **QEMU inside EC2 (not recommended)** | Nested virtualization — VMs inside a VM on AWS | Only if you specifically need to practice PXE/libvirt/Metal3. Requires bare-metal EC2 instances, costs more, adds complexity |

For your goals (Terraform + AWS + automated failover + cloud engineering learning), **EC2 instances are your bare-metal servers**. The workflow is identical to real bare-metal provisioning:

```
Terraform apply
  → EC2 instances launch
    → cloud-init injects SSH keys, hostname, packages
      → Ansible installs k3s, Cilium, Longhorn, Traefik
        → Argo CD deploys apps from Git
```

You are not "cheating" by skipping QEMU — in production, bare-metal provisioning means "install OS on a physical server and configure it," and EC2 with cloud-init + Ansible is the cloud equivalent.

---

## Architecture Diagram

```
                         ┌─────────────────────────────────────┐
                         │           Route53                      │
                         │  app.yourdomain.com                   │
                         │  (failover routing policy)            │
                         └──────────┬──────────────┬─────────────┘
                                    │              │
                          PRIMARY (healthy)    STANDBY (on failure)
                                    │              │
┌───────────────────────────────────▼──┐  ┌───────▼──────────────────────────┐
│  PRIMARY CLUSTER (AZ-a + AZ-b)       │  │  STANDBY CLUSTER (AZ-c)          │
│                                      │  │                                  │
│  ┌─────────┐ ┌─────────┐ ┌────────┐ │  │  ┌─────────┐ ┌─────────┐        │
│  │ CP-1    │ │ CP-2    │ │ CP-3   │ │  │  │ SB-1    │ │ SB-2    │        │
│  │t4g.small│ │t4g.small│ │t4g.small│ │  │  │t4g.micro│ │t4g.micro│        │
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
                              │  S3 Backup Bucket  │
                              └───────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│  SHARED SERVICES                                                            │
│                                                                             │
│  Lambda Witness (every 1 min)                                               │
│    → checks primary k3s API /readyz                                         │
│    → on 3 failures: trigger failover Step Function                          │
│                                                                             │
│  Step Functions Failover Workflow:                                          │
│    1. Confirm primary is down                                               │
│    2. Velero restore latest backup to standby                               │
│    3. Scale standby app replicas 0 → N (patch Git or Argo CD apps)          │
│    4. Route53 failover record → standby ALB/NLB                             │
│    5. SNS notification                                                      │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Why Pre-Deploy Argo CD on the Standby Cluster

**Yes — absolutely pre-deploy Argo CD on standby.** This is required for fully automated failover.

If Argo CD only lives on the primary cluster, a total primary failure means:

- You cannot patch Application destinations (API is gone)
- You cannot sync apps to standby
- Failover degrades to manual `kubectl apply` or Velero restore only

### Dual Argo CD Pattern

| Component | Primary cluster | Standby cluster |
|-----------|----------------|-----------------|
| Argo CD | Active — syncs apps with `replicas: N` | Active — syncs same Git repo, apps at `replicas: 0` |
| Traefik | Receives traffic via Route53 | Installed but idle |
| Monitoring | Full Prometheus stack | Lightweight — enough for health checks |
| Longhorn | Active storage | Not needed (state restored via Velero) |

Both Argo CD instances watch the **same Git repo**. Standby apps use a Kustomize overlay or Helm values to set `replicas: 0` until failover.

On failover, the Step Function (or script) either:

1. Patches the standby Argo CD Application to scale replicas up, or
2. Merges a Git commit that switches the `active-cluster` label (GitOps-native), or
3. Uses an ApplicationSet cluster label selector — witness updates the `active=true` label on the standby cluster secret

**Recommended for full automation:** ApplicationSet with cluster label `role=active|passive`. Witness flips labels; ApplicationSet redeploys automatically.

---

## Domain — Do You Need One?

**Yes. Get a domain for fully automated DNS failover.**

Without a domain, you can still fail over using:

- Elastic IP reassignment (manual/scripted, not health-check native)
- NLB DNS names ( ugly URLs, hard to automate cleanly)
- ALB target group switching (works but not user-facing)

For production-like automated failover, Route53 needs a hosted zone, which requires a domain.

### Recommended Setup

| Step | Action | Cost |
|------|--------|------|
| 1 | Register domain via Route53 or Namecheap/Cloudflare | ~$10–15/year (.com) |
| 2 | Create Route53 hosted zone | $0.50/month |
| 3 | Configure failover routing policy (primary + standby records) | ~$0.50/month per health check |
| 4 | Point domain NS to Route53 | Free |

**Budget option:** Register via Cloudflare (~$10/year), use Cloudflare DNS with API-based failover instead of Route53 health checks. The starter scripts support both.

**Until you have a domain:** Use the primary ALB/NLB DNS name directly for testing. Add Route53 failover in Phase 4 when the domain is ready.

---

## Terraform Project Structure

```
├── primary-cluster/          # Project 1: EC2 nodes for primary k3s HA
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   └── cloud-init/
│
├── cloud-services/           # Project 2: EC2 standby nodes + S3 + IAM
│   ├── main.tf
│   ├── variables.tf
│   └── outputs.tf
│
├── shared-services/          # Project 3: Route53, Lambda witness, Step Functions
│   ├── main.tf
│   ├── variables.tf
│   ├── lambda/
│   │   └── health_check.py
│   └── step_functions/
│       └── failover.asl.json
│
├── ansible/                  # Bootstraps both clusters
├── gitops/                   # Argo CD manifests (both clusters)
└── docs/
```

Apply order: `primary-cluster` → `cloud-services` → Ansible → `shared-services` (needs domain for Route53).

---

## Instance Sizing (AWS)

### Primary Cluster

| Node | Role | Instance | vCPU | RAM | ~$/mo |
|------|------|----------|------|-----|-------|
| cp-1 | k3s server | t4g.small | 2 | 2 GB | ~$12 |
| cp-2 | k3s server | t4g.small | 2 | 2 GB | ~$12 |
| cp-3 | k3s server | t4g.small | 2 | 2 GB | ~$12 |
| w-1 | k3s agent | t4g.small | 2 | 2 GB | ~$12 |
| w-2 | k3s agent | t4g.small | 2 | 2 GB | ~$12 |
| **Subtotal** | | | | | **~$60/mo** |

For a learning/dev setup, reduce to 1 server + 2 agents (~$36/mo):

| Node | Role | Instance | ~$/mo |
|------|------|----------|-------|
| cp-1 | k3s server (single) | t4g.small | ~$12 |
| w-1 | k3s agent | t4g.small | ~$12 |
| w-2 | k3s agent | t4g.small | ~$12 |

### Standby Cluster

| Node | Role | Instance | vCPU | RAM | ~$/mo |
|------|------|----------|------|-----|-------|
| sb-1 | k3s server | t4g.micro | 2 | 1 GB | ~$6 |
| sb-2 | k3s agent | t4g.micro | 2 | 1 GB | ~$6 |
| **Subtotal** | | | | | **~$12/mo** |

### Shared Services

| Service | ~$/mo |
|---------|-------|
| S3 backups (100 GB) | ~$2 |
| Lambda witness | ~$0 |
| Route53 hosted zone + health check | ~$1 |
| **Subtotal** | **~$3/mo** |

### Total

| Config | ~$/mo |
|--------|-------|
| Dev (1+2 primary, 2 standby) | ~$51 |
| HA (3+2 primary, 2 standby) | ~$75 |

This is more than the local-QEMU hybrid (~$15/mo) because primary compute is now on AWS too. The trade-off: everything in one cloud account, no local hardware needed, fully reproducible.

---

## Failover Flow (Fully Automated)

```
1. Lambda (every 60s)
     └─► GET https://primary-api:6443/readyz
           └─► 3 consecutive failures?

2. Step Functions: FailoverWorkflow
     ├─► Confirm primary unreachable (double-check)
     ├─► Run Velero restore on standby cluster (latest backup)
     ├─► Patch Argo CD cluster labels:
     │     primary: role=passive
     │     standby: role=active
     ├─► ApplicationSet redeploys apps with replicas > 0 on standby
     ├─► Route53 failover record switches to standby NLB
     └─► SNS → email/Slack: "FAILOVER COMPLETE"

3. Standby cluster now serves traffic

4. Failback (manual trigger or auto when primary recovers):
     ├─► Verify primary healthy (5 checks)
     ├─► Sync apps back to primary via Argo CD
     ├─► Route53 switches back
     └─► Standby returns to replicas=0 idle state
```

---

## Implementation Phases

| Phase | What | Domain needed? | ~Cost |
|-------|------|----------------|-------|
| 1 | Primary EC2 + k3s via Terraform/Ansible | No | ~$36/mo |
| 2 | Standby EC2 + Velero S3 backups | No | +$14/mo |
| 3 | Dual Argo CD + GitOps sync | No | $0 |
| 4 | Lambda witness + Step Functions + Route53 | **Yes** | +$3/mo |

You can build Phases 1–3 without a domain. Buy the domain before Phase 4.

---

## Next Steps

1. Register a domain (Route53 or Cloudflare)
2. `terraform apply` in `primary-cluster/`
3. Run Ansible against primary nodes
4. `terraform apply` in `cloud-services/`
5. Run Ansible against standby nodes
6. Deploy Argo CD on both clusters
7. `terraform apply` in `shared-services/` (after domain is ready)
8. Test failover by stopping primary EC2 instances
