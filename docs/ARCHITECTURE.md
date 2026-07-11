# Hybrid Bare-Metal Kubernetes Platform

**Local Primary + Cloud Standby with Automated Failover**

| Field | Value |
|-------|-------|
| Version | 1.0 |
| Last Updated | July 2026 |
| Target Audience | Cloud engineers, homelab builders, hybrid infra learners |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Why This Project Matters for Cloud Engineering](#2-why-this-project-matters-for-cloud-engineering)
3. [Architecture Overview](#3-architecture-overview)
4. [Technology Stack](#4-technology-stack)
5. [Terraform Project Structure](#5-terraform-project-structure)
6. [Phase 1: Local Bare-Metal Simulation](#6-phase-1-local-bare-metal-simulation)
7. [Phase 2: Cloud Standby Cluster](#7-phase-2-cloud-standby-cluster)
8. [Phase 3: Backup, Observability, and Secrets](#8-phase-3-backup-observability-and-secrets)
9. [Phase 4: Automated Failover](#9-phase-4-automated-failover)
10. [Argo CD Configuration (GitOps Layer)](#10-argo-cd-configuration-gitops-layer)
11. [Traefik on Edge Hardware (Raspberry Pi)](#11-traefik-on-edge-hardware-raspberry-pi)
12. [Cost Model](#12-cost-model)
13. [Learning Outcomes](#13-learning-outcomes)
14. [Appendix: Tool Alternatives](#14-appendix-tool-alternatives)

---

## 1. Executive Summary

This platform simulates bare-metal Kubernetes provisioning locally (QEMU/libvirt VMs or real Raspberry Pi / Mac Mini hardware), runs a lightweight **k3s** cluster as the primary workload plane, and maintains a **warm cloud standby** cluster for automated disaster recovery. Infrastructure is declared with **Terraform**, nodes are configured with **Ansible**, applications are deployed via **Argo CD**, and failover is orchestrated through monitoring + DNS switching.

**Core design principles:**

- **Local for cost and performance** — 99% of compute runs on your hardware.
- **Cloud for resilience** — backups, standby nodes, managed services, and the failover witness.
- **GitOps for everything** — one Git repo is the source of truth for both clusters.
- **Separation of concerns** — distinct Terraform projects for local VMs vs. cloud resources.

---

## 2. Why This Project Matters for Cloud Engineering

This is not a toy homelab exercise. It maps directly to production cloud engineering responsibilities:

| Skill Area | What You Practice |
|------------|-------------------|
| Infrastructure as Code | Multi-project Terraform, remote state, module composition |
| Hybrid / multi-cloud | Local + AWS/GCP/Azure integration, cost-aware architecture |
| High availability | Active-passive failover, DNS cutover, backup/restore |
| Kubernetes operations | k3s bootstrap, CNI, storage, multi-cluster management |
| GitOps | Argo CD ApplicationSets, sync policies, multi-cluster targeting |
| Observability | Prometheus, Alertmanager, Grafana, Argo CD notifications |
| Bare-metal concepts | PXE/cloud-init provisioning, immutable images, node lifecycle |
| Edge computing | Traefik ingress on ARM hardware (Raspberry Pi) |

**Portfolio value:** A documented, working hybrid platform with automated failover demonstrates skills that many cloud engineers only know theoretically.

---

## 3. Architecture Overview

### 3.1 High-Level Diagram

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        LOCAL ENVIRONMENT                                │
│  (QEMU/libvirt VMs simulating bare metal, or real Pi/Mac Mini nodes)  │
│                                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│  │ Node 1   │  │ Node 2   │  │ Node 3   │  │ Node 4   │               │
│  │ (control)│  │ (control)│  │ (control)│  │ (worker) │               │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘               │
│       └──────────────┴──────────────┴──────────────┘                   │
│                          k3s Primary Cluster                            │
│       ┌──────────────────────────────────────────────┐                  │
│       │ Longhorn │ Cilium │ Traefik │ Prometheus     │                  │
│       │ Argo CD  │ Velero │ Apps (via GitOps)        │                  │
│       └──────────────────────────────────────────────┘                  │
└───────────────────────────────┬─────────────────────────────────────────┘
                                │
                    Velero backups / etcd snapshots
                    Prometheus remote write (optional)
                                │
┌───────────────────────────────▼─────────────────────────────────────────┐
│                        CLOUD ENVIRONMENT                                │
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌─────────────────────────────┐   │
│  │ Standby Node │  │ Standby Node │  │ Witness / Failover Controller│   │
│  │ (t4g.nano)   │  │ (t4g.nano)   │  │ (Lambda or tiny VM)         │   │
│  └──────┬───────┘  └──────┬───────┘  └──────────────┬──────────────┘   │
│         └─────────────────┴────────────────────────┘                   │
│                    k3s Standby Cluster                                  │
│                                                                         │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌──────────────────┐  │
│  │ S3/GCS     │  │ ExternalDNS│  │ Cloud LB   │  │ Secrets Manager  │  │
│  │ (backups)  │  │ + Cloudflare│ │ (failover) │  │ (External Secrets)│  │
│  └────────────┘  └────────────┘  └────────────┘  └──────────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│                           SHARED LAYER                                  │
│  Git Repository (Argo CD source) │ Terraform Remote State (S3)         │
└─────────────────────────────────────────────────────────────────────────┘
```

### 3.2 Failover Sequence

```
Normal operation:
  Traffic → Cloudflare DNS → Local Traefik → Local Apps
  Witness polls local API server every 30s → healthy

Failure detected (3 consecutive failures):
  1. Witness confirms local cluster unreachable
  2. Witness triggers failover script:
     a. Restore latest Velero backup to cloud cluster (if needed)
     b. Patch Argo CD Applications → destination = cloud-standby
     c. Argo CD syncs all apps to cloud cluster
     d. Update Cloudflare DNS → cloud load balancer IP
  3. Alertmanager sends Slack/email notification

Failback (when local recovers):
  1. Verify local cluster health
  2. Sync apps back to local via Argo CD
  3. Update DNS → local Traefik
  4. Cloud standby returns to warm idle state
```

### 3.3 Component Responsibilities

| Component | Location | Role |
|-----------|----------|------|
| k3s Primary | Local VMs | Main workload, control plane |
| k3s Standby | Cloud (1–3 tiny nodes) | Warm standby, receives traffic on failover |
| Witness | Cloud (Lambda or nano VM) | Health checks, triggers failover |
| Velero | Both clusters | Backup/restore etcd + PVs to S3 |
| Argo CD | Local primary | GitOps controller for both clusters |
| ExternalDNS | Both clusters | DNS record management |
| Traefik | Local primary | Ingress controller |
| Longhorn | Local primary | Distributed block storage |
| Prometheus | Local primary | Metrics + alerting |
| Terraform (local) | Your laptop / control node | Provisions QEMU VMs |
| Terraform (cloud) | Your laptop / control node | Provisions cloud resources |

---

## 4. Technology Stack

| Layer | Tool | Version (pin in prod) | Purpose |
|-------|------|----------------------|---------|
| VM Provisioning | Terraform + libvirt provider | ≥ 1.5 | Create simulated bare-metal nodes |
| OS Bootstrap | cloud-init | — | First-boot config (SSH keys, packages) |
| Config Management | Ansible | ≥ 2.15 | k3s install, hardening, add-ons |
| Kubernetes | k3s | ≥ 1.28 | Lightweight K8s distribution |
| CNI | Cilium | ≥ 1.14 | Networking, network policies, Hubble |
| Storage | Longhorn | ≥ 1.5 | Distributed block storage |
| Ingress | Traefik | v3 | HTTP/HTTPS routing, Let's Encrypt |
| GitOps | Argo CD | ≥ 2.9 | Declarative app deployment |
| Backup | Velero + Restic | ≥ 1.12 | Cluster + PV backup to S3 |
| Monitoring | Prometheus + Grafana | — | Metrics, dashboards, alerting |
| Alerting | Alertmanager | — | Route alerts to Slack/email |
| DNS | ExternalDNS + Cloudflare | — | Automated DNS for failover |
| Secrets | External Secrets Operator | — | Pull secrets from cloud SM |
| Cloud IaC | Terraform (AWS/GCP/Azure) | ≥ 1.5 | Cloud standby, S3, networking |
| Failover | Custom witness script | — | Health check + DNS/Argo CD patch |

---

## 5. Terraform Project Structure

```
hybrid-k8s-platform/
├── bare-metal-simulation/       # Project 1: local VM provisioning
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── cloud-init/
│   │   └── node.yaml.tftpl
│   └── README.md
│
├── cloud-services/              # Project 2: cloud standby + shared services
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── modules/
│   │   ├── standby-cluster/
│   │   ├── backup-storage/
│   │   └── witness/
│   └── README.md
│
├── ansible/                       # Node configuration (post-Terraform)
│   ├── ansible.cfg
│   ├── inventory/
│   │   └── hosts.yml            # Generated from Terraform outputs
│   ├── playbooks/
│   │   ├── site.yml
│   │   ├── k3s-install.yml
│   │   └── k3s-addons.yml
│   └── roles/
│       ├── common/
│       ├── k3s-server/
│       └── k3s-agent/
│
├── gitops/                        # Argo CD manifests (Application source)
│   ├── argocd/
│   │   ├── install/
│   │   ├── clusters/
│   │   ├── applications/
│   │   └── applicationsets/
│   ├── apps/
│   │   ├── local/
│   │   └── cloud/
│   └── infrastructure/
│       ├── longhorn/
│       ├── cilium/
│       ├── traefik/
│       ├── velero/
│       └── monitoring/
│
├── scripts/
│   ├── failover.sh
│   ├── failback.sh
│   └── health-check.sh
│
└── docs/
    └── ARCHITECTURE.md            # This document
```

### 5.1 Remote State

Both Terraform projects share state via an S3 backend (created once, manually or via a bootstrap script):

```hcl
terraform {
  backend "s3" {
    bucket         = "hybrid-k8s-tfstate"
    key            = "bare-metal/terraform.tfstate"  # or "cloud/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "hybrid-k8s-tfstate-lock"
  }
}
```

**Cross-project data flow:**

```
bare-metal-simulation outputs          cloud-services reads
─────────────────────────────          ──────────────────────
node_ips[]                    ──────►  security group ingress rules
node_count                    ──────►  standby node sizing decisions
ssh_public_key                ──────►  cloud instance key pair
```

Use `terraform_remote_state` data source in the cloud project:

```hcl
data "terraform_remote_state" "bare_metal" {
  backend = "s3"
  config = {
    bucket = "hybrid-k8s-tfstate"
    key    = "bare-metal/terraform.tfstate"
    region = "us-east-1"
  }
}
```

---

## 6. Phase 1: Local Bare-Metal Simulation

### 6.1 Prerequisites

```bash
# Ubuntu/Debian host (your laptop or a dedicated machine)
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients \
  virt-manager bridge-utils cloud-image-utils genisoimage

# Add yourself to libvirt group
sudo usermod -aG libvirt $USER
newgrp libvirt

# Verify KVM
virsh list --all
```

### 6.2 VM Topology

| Node | Role | vCPU | RAM | Disk |
|------|------|------|-----|------|
| node-1 | k3s server (control plane) | 2 | 4 GB | 40 GB |
| node-2 | k3s server (control plane) | 2 | 4 GB | 40 GB |
| node-3 | k3s server (control plane) | 2 | 4 GB | 40 GB |
| node-4 | k3s agent (worker) | 2 | 4 GB | 40 GB |
| node-5 | k3s agent (worker) | 2 | 4 GB | 40 GB |

**Minimum host requirements:** 16 GB RAM, 8+ vCPU, 250 GB disk, KVM support.

### 6.3 Provisioning Flow

```
Terraform apply
  └─► Creates libvirt network + cloud-init ISOs + VMs
        └─► VMs boot Ubuntu 24.04 cloud image
              └─► cloud-init: SSH keys, hostname, base packages
                    └─► Ansible site.yml
                          └─► k3s HA cluster (3 servers + N agents)
                                └─► k3s-addons.yml (Cilium, Longhorn, Traefik)
```

### 6.4 cloud-init Template

See `bare-metal-simulation/cloud-init/node.yaml.tftpl` for the full template. Key sections:

- **users:** SSH key injection, sudo access
- **packages:** curl, open-iscsi (Longhorn), jq
- **write_files:** k3s config placeholders
- **runcmd:** disable swap, load kernel modules for Cilium

### 6.5 Ansible Bootstrap

After Terraform outputs node IPs, generate inventory and run:

```bash
cd ansible
ansible-playbook -i inventory/hosts.yml playbooks/site.yml
```

The `site.yml` playbook chain:

1. **common** role — hardening, packages, kernel modules
2. **k3s-server** role — install k3s on first 3 nodes (embedded etcd HA)
3. **k3s-agent** role — join worker nodes
4. **k3s-addons** — deploy Cilium, Longhorn, Traefik via Helm

---

## 7. Phase 2: Cloud Standby Cluster

### 7.1 Cloud Resources (Terraform)

| Resource | Spec | Purpose |
|----------|------|---------|
| EC2 / GCE instances (×2) | t4g.nano / e2-micro | k3s standby nodes |
| S3 / GCS bucket | Standard tier | Velero backups + TF state |
| Security groups | Minimal ingress | SSH + k3s API (6443) from your IP |
| IAM role | S3 read/write | Velero + External Secrets |
| Lambda / Cloud Function | 128 MB, triggered every 1 min | Witness health check |
| Route53 / Cloudflare | DNS records | Failover DNS switching |

### 7.2 Standby Cluster Bootstrap

The cloud standby mirrors the local cluster configuration via GitOps:

1. Terraform provisions 2 cloud instances with the same cloud-init + Ansible flow.
2. A second k3s cluster is bootstrapped (can be single-server for cost savings).
3. Argo CD on the local cluster registers the cloud cluster as a destination.
4. ApplicationSets deploy the same app manifests to both clusters.
5. Cloud standby nodes are tainted: `standby=true:NoSchedule` so workloads only land there during failover.

### 7.3 Keeping Standby in Sync

| Method | Frequency | What Syncs |
|--------|-----------|------------|
| Velero scheduled backup | Every 6 hours | etcd state + PV snapshots |
| Argo CD auto-sync | Continuous | Application manifests |
| etcd snapshot | Every 1 hour | Control plane state |

---

## 8. Phase 3: Backup, Observability, and Secrets

### 8.1 Velero Configuration

```yaml
# gitops/infrastructure/velero/values.yaml
configuration:
  backupStorageLocation:
    - name: aws-s3
      provider: aws
      bucket: hybrid-k8s-backups
      config:
        region: us-east-1
  volumeSnapshotLocation:
    - name: aws-s3
      provider: aws
      config:
        region: us-east-1

schedules:
  full-backup:
    schedule: "0 */6 * * *"    # Every 6 hours
    template:
      ttl: 720h                 # 30-day retention
      includedNamespaces:
        - "*"
      snapshotVolumes: true
  etcd-only:
    schedule: "0 * * * *"      # Hourly etcd
    template:
      ttl: 168h                 # 7-day retention
      includedResources:
        - "*"
      excludedNamespaces:
        - kube-system
        - velero
```

### 8.2 Prometheus Alerting Rules

Key alerts for failover triggers:

```yaml
groups:
  - name: cluster-health
    rules:
      - alert: KubeAPIDown
        expr: up{job="kubernetes-apiservers"} == 0
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "Kubernetes API server unreachable"

      - alert: NodeNotReady
        expr: kube_node_status_condition{condition="Ready",status="true"} == 0
        for: 5m
        labels:
          severity: warning

      - alert: MultipleNodesDown
        expr: count(kube_node_status_condition{condition="Ready",status="true"} == 0) > 2
        for: 3m
        labels:
          severity: critical
        annotations:
          summary: "More than 2 nodes down — consider failover"
```

### 8.3 External Secrets

Pull secrets from AWS Secrets Manager (or GCP Secret Manager) into both clusters:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
            namespace: external-secrets
```

---

## 9. Phase 4: Automated Failover

### 9.1 Failover Levels

| Level | Automation | Cloud Cost | Recovery Time |
|-------|-----------|------------|---------------|
| 1 — Backup only | Manual restore | ~$5/mo | 30–60 min |
| 2 — Warm standby | Scripted (cron/Lambda) | ~$15–30/mo | 5–15 min |
| 3 — Full active-passive | Fully automated | ~$30–60/mo | 1–5 min |

This architecture targets **Level 3**.

### 9.2 Witness Component

A lightweight always-on process in the cloud that:

1. Polls the local k3s API server (`/readyz` or `/healthz`) every 30 seconds.
2. Tracks consecutive failures (threshold: 3 = 90 seconds).
3. On threshold breach, executes the failover script.
4. Sends notifications via Alertmanager webhook or direct Slack API.

**Implementation options:**

| Option | Cost | Complexity |
|--------|------|------------|
| AWS Lambda + EventBridge (1-min schedule) | ~$0/mo (free tier) | Low |
| Tiny EC2 instance (t4g.nano) | ~$3/mo | Low |
| Kubernetes CronJob on cloud standby | $0 (uses existing node) | Medium |

Recommended: **Lambda + EventBridge** for zero idle cost.

### 9.3 Failover Script Logic

See `scripts/failover.sh` for the full implementation. Summary:

```
1. Confirm local cluster is down (double-check from witness)
2. Check cloud standby cluster health
3. Restore latest Velero backup to cloud cluster (if PVs needed)
4. Patch all Argo CD Applications:
     destination.server → cloud-standby API endpoint
5. Wait for Argo CD sync completion
6. Update Cloudflare DNS A record → cloud load balancer IP
7. Send notification: "FAILOVER COMPLETE — traffic now routed to cloud"
8. Set failover state flag (prevent repeated triggers)
```

### 9.4 Failback Script Logic

See `scripts/failback.sh`. Summary:

```
1. Confirm local cluster is healthy (5 consecutive successful checks)
2. Sync apps back to local via Argo CD destination patch
3. Restore any PV data from Velero if needed
4. Update DNS → local Traefik IP
5. Cloud standby returns to tainted idle state
6. Send notification: "FAILBACK COMPLETE — traffic restored to local"
```

### 9.5 DNS Failover with Cloudflare

Use Cloudflare API (or ExternalDNS with a custom annotation) to switch records:

```bash
# Failover: point app.example.com to cloud LB
curl -X PUT "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/dns_records/$RECORD_ID" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{"type":"A","name":"app.example.com","content":"CLOUD_LB_IP","ttl":60,"proxied":true}'
```

Low TTL (60s) ensures fast propagation during failover.

---

## 10. Argo CD Configuration (GitOps Layer)

Argo CD is the declarative GitOps engine for the entire platform. It ensures the desired state defined in Git is continuously reconciled on both local and cloud clusters.

### 10.1 Architecture

```
┌─────────────────────────────────────────────────────┐
│                  Argo CD (on local primary)          │
│                                                     │
│  ┌─────────────┐  ┌──────────────┐  ┌───────────┐  │
│  │ App of Apps  │  │ AppSets      │  │ Notifs    │  │
│  │ (bootstrap)  │  │ (multi-clust)│  │ (Slack)   │  │
│  └──────┬──────┘  └──────┬───────┘  └───────────┘  │
│         │                │                          │
│    ┌────▼────────────────▼─────┐                    │
│    │     Registered Clusters    │                    │
│    │  ┌─────────┐ ┌───────────┐ │                    │
│    │  │ local   │ │ cloud     │ │                    │
│    │  │ primary │ │ standby   │ │                    │
│    │  └─────────┘ └───────────┘ │                    │
│    └────────────────────────────┘                    │
└─────────────────────────────────────────────────────┘
         │                        │
    syncs apps              syncs apps (on failover)
         │                        │
    ┌────▼─────┐           ┌─────▼────┐
    │  Local   │           │  Cloud   │
    │  k3s     │           │  k3s     │
    └──────────┘           └──────────┘
```

### 10.2 Installation

```bash
kubectl create namespace argocd
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=NodePort \
  --set configs.params."server\.insecure"=true
```

Or declaratively via GitOps (see `gitops/argocd/install/values.yaml`).

### 10.3 Cluster Registration

**Local cluster** (in-cluster — Argo CD runs here):

```yaml
# gitops/argocd/clusters/local-cluster.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cluster-local-primary
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    environment: primary
type: Opaque
stringData:
  name: local-primary
  server: https://kubernetes.default.svc
  config: |
    {
      "tlsClientConfig": {
        "insecure": false
      }
    }
```

**Cloud standby cluster:**

```yaml
# gitops/argocd/clusters/cloud-standby.yaml
apiVersion: v1
kind: Secret
metadata:
  name: cluster-cloud-standby
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
    environment: standby
type: Opaque
stringData:
  name: cloud-standby
  server: https://CLOUD_API_ENDPOINT:6443
  config: |
    {
      "bearerToken": "CLOUD_SERVICE_ACCOUNT_TOKEN",
      "tlsClientConfig": {
        "caData": "BASE64_CA_CERT"
      }
    }
```

Generate the cloud cluster token:

```bash
# On cloud standby cluster
kubectl create sa argocd-manager -n kube-system
kubectl create clusterrolebinding argocd-manager \
  --clusterrole=cluster-admin \
  --serviceaccount=kube-system:argocd-manager
TOKEN=$(kubectl create token argocd-manager -n kube-system)
```

### 10.4 App of Apps Pattern

The root Application bootstraps everything else:

```yaml
# gitops/argocd/applications/root-app.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root-app
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/yourorg/hybrid-k8s-gitops.git
    targetRevision: main
    path: gitops/argocd/applications
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

Child applications (in `gitops/argocd/applications/`) include:

- `infra-cilium.yaml`
- `infra-longhorn.yaml`
- `infra-traefik.yaml`
- `infra-velero.yaml`
- `infra-monitoring.yaml`
- `apps-core-services.yaml` (ApplicationSet)

### 10.5 ApplicationSets for Multi-Cluster Deployment

Deploy core infrastructure to both clusters with a single ApplicationSet:

```yaml
# gitops/argocd/applicationsets/core-infra.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: core-infra
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchLabels:
            environment: primary
        values:
          clusterRole: primary
    - clusters:
        selector:
          matchLabels:
            environment: standby
        values:
          clusterRole: standby
  template:
    metadata:
      name: 'infra-{{values.clusterRole}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/yourorg/hybrid-k8s-gitops.git
        targetRevision: main
        path: 'gitops/infrastructure/{{values.clusterRole}}'
      destination:
        server: '{{server}}'
        namespace: default
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

Deploy applications only to the active cluster (controlled by a label):

```yaml
# gitops/argocd/applicationsets/apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: applications
  namespace: argocd
spec:
  generators:
    - git:
        repoURL: https://github.com/yourorg/hybrid-k8s-gitops.git
        revision: main
        directories:
          - path: gitops/apps/*
  template:
    metadata:
      name: '{{path.basename}}'
      labels:
        app.kubernetes.io/part-of: hybrid-platform
    spec:
      project: default
      source:
        repoURL: https://github.com/yourorg/hybrid-k8s-gitops.git
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc  # Default: local primary
        namespace: '{{path.basename}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
```

### 10.6 Failover Integration with Argo CD

During failover, patch Application destinations to the cloud cluster:

```bash
#!/usr/bin/env bash
# scripts/failover-argocd.sh

CLOUD_SERVER="https://CLOUD_API_ENDPOINT:6443"

for app in $(kubectl get applications -n argocd -o name); do
  kubectl patch "$app" -n argocd --type merge -p "{
    \"spec\": {
      \"destination\": {
        \"server\": \"${CLOUD_SERVER}\"
      }
    }
  }"
done

# Force sync all apps
argocd app sync --all --force
```

During failback, reverse the patch:

```bash
LOCAL_SERVER="https://kubernetes.default.svc"

for app in $(kubectl get applications -n argocd -o name); do
  kubectl patch "$app" -n argocd --type merge -p "{
    \"spec\": {
      \"destination\": {
        \"server\": \"${LOCAL_SERVER}\"
      }
    }
  }"
done
```

### 10.7 Sync Waves and Hooks

Order deployments during failover using sync waves:

```yaml
# Example: database must come before app
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  annotations:
    argocd.argoproj.io/sync-wave: "1"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    argocd.argoproj.io/hook: PostSync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
```

### 10.8 Notifications

Configure Argo CD Notifications for Slack alerts on sync failures and failover events:

```yaml
# gitops/argocd/notifications/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.slack: |
    token: $slack-token
  template.app-sync-failed: |
    message: |
      :x: Application {{.app.metadata.name}} failed to sync.
      Cluster: {{.app.spec.destination.server}}
      Error: {{.app.status.conditions}}
  template.app-sync-succeeded: |
    message: |
      :white_check_mark: Application {{.app.metadata.name}} synced successfully.
  trigger.on-sync-failed: |
    - when: app.status.operationState.phase in ['Error', 'Failed']
      send: [app-sync-failed]
  trigger.on-sync-succeeded: |
    - when: app.status.operationState.phase == 'Succeeded'
      send: [app-sync-succeeded]
```

### 10.9 RBAC

Restrict developer access to their own apps:

```yaml
# gitops/argocd/projects/developers.yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: developers
  namespace: argocd
spec:
  description: Developer applications
  sourceRepos:
    - 'https://github.com/yourorg/*'
  destinations:
    - namespace: 'dev-*'
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceWhitelist:
    - group: 'apps'
      kind: Deployment
    - group: ''
      kind: Service
    - group: ''
      kind: ConfigMap
```

### 10.10 Monitoring Argo CD

Scrape Argo CD metrics with Prometheus:

```yaml
# ServiceMonitor for Argo CD
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: argocd-metrics
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: argocd-metrics
  endpoints:
    - port: metrics
      interval: 30s
```

Key metrics to alert on:

| Metric | Alert Condition |
|--------|----------------|
| `argocd_app_sync_total{phase="Failed"}` | Any increase in 5 min |
| `argocd_app_health_status{health_status!="Healthy"}` | Sustained unhealthy |
| `argocd_cluster_connection_status{connected="0"}` | Cloud cluster disconnected |

---

## 11. Traefik on Edge Hardware (Raspberry Pi)

Traefik runs well on Raspberry Pi and serves as the ingress controller for the local primary cluster. It can also run standalone on a Pi as a standalone reverse proxy.

### 11.1 Standalone Traefik on Pi (Docker)

```yaml
# docker-compose.yml for Raspberry Pi
services:
  traefik:
    image: traefik:v3.0
    container_name: traefik
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik.yml:/etc/traefik/traefik.yml:ro
      - ./dynamic:/etc/traefik/dynamic:ro
      - ./acme.json:/acme.json
    labels:
      - "traefik.enable=true"
```

```yaml
# traefik.yml
entryPoints:
  web:
    address: ":80"
    http:
      redirections:
        entryPoint:
          to: websecure
  websecure:
    address: ":443"

providers:
  docker:
    exposedByDefault: false
  file:
    directory: /etc/traefik/dynamic
    watch: true

certificatesResolvers:
  letsencrypt:
    acme:
      email: your@email.com
      storage: /acme.json
      httpChallenge:
        entryPoint: web

api:
  dashboard: true
```

### 11.2 Traefik as k3s Ingress

When running inside the k3s cluster (recommended for this project):

```bash
# Disable k3s default Traefik if installing custom
curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable traefik" sh -

# Install via Helm with NodePort or LoadBalancer
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set ports.web.nodePort=30080 \
  --set ports.websecure.nodePort=30443
```

### 11.3 Pi-Specific Tips

- Use **64-bit Raspberry Pi OS** (Bookworm+) for native arm64 Docker images.
- Pi 4 (4 GB+) or Pi 5 recommended when running k3s + Traefik + apps.
- Memory footprint: Traefik alone uses ~50–80 MB.
- For production: secure the dashboard, use DNS-01 challenge for wildcard certs.

---

## 12. Cost Model

### 12.1 Monthly Estimate (Full Active-Passive)

| Component | Spec | Monthly Cost |
|-----------|------|-------------|
| Local compute | Your hardware / QEMU host | $0–5 (electricity) |
| Cloud standby nodes (×2) | t4g.nano (ARM) | $6–12 |
| Witness (Lambda) | 1-min schedule, 128 MB | $0 (free tier) |
| S3 backups (100 GB) | Standard tier | $2–3 |
| S3 TF state + DynamoDB | Minimal | $1 |
| Cloudflare DNS | Free plan | $0 |
| Data transfer (failover events) | Occasional | $1–5 |
| **Total** | | **$10–25/mo** |

During normal operation with no failover, you primarily pay for 2 tiny cloud nodes and storage. The $30–60/mo range from earlier estimates assumes slightly larger standby nodes or frequent failover testing.

### 12.2 Cost Comparison

| Approach | Monthly Cost | Failover |
|----------|-------------|----------|
| Full cloud (EKS 3-node) | $200–500+ | Built-in |
| This hybrid platform | $10–25 | Automated (1–5 min) |
| Local only (no cloud) | $0–5 | Manual (hours) |
| Backups only (no standby) | $2–10 | Manual restore (30–60 min) |

---

## 13. Learning Outcomes

After completing this project, you will have hands-on experience with:

1. **Multi-project Terraform** — libvirt provider, remote state, cross-project outputs
2. **Ansible automation** — idempotent playbooks, dynamic inventory, role composition
3. **Kubernetes operations** — k3s HA, CNI, storage, ingress, multi-cluster
4. **GitOps with Argo CD** — ApplicationSets, multi-cluster sync, notifications, RBAC
5. **Disaster recovery** — Velero backup/restore, automated failover, DNS cutover
6. **Observability** — Prometheus alerting, Grafana dashboards, Alertmanager routing
7. **Hybrid cloud patterns** — cost optimization, active-passive, witness-based failover
8. **Edge computing** — Traefik on ARM, lightweight K8s on constrained hardware
9. **Security** — External Secrets, network policies (Cilium), RBAC, TLS everywhere

---

## 14. Appendix: Tool Alternatives

| Layer | Primary Choice | Alternatives |
|-------|---------------|-------------|
| VM provisioning | Terraform + libvirt | Packer, virt-install scripts, MAAS |
| Config management | Ansible | Salt, Puppet, cloud-init only |
| Kubernetes | k3s | kubeadm, Talos Linux, RKE2 |
| CNI | Cilium | Calico, Flannel |
| Storage | Longhorn | Rook-Ceph, OpenEBS, local-path |
| GitOps | Argo CD | FluxCD, Fleet |
| Backup | Velero | etcd snapshot + restic manual |
| Ingress | Traefik | NGINX, HAProxy, Caddy |
| Monitoring | Prometheus stack | Datadog (paid), Netdata |
| Cloud IaC | Terraform | OpenTofu, Pulumi, Crossplane |
| Bare-metal provisioning | cloud-init + Ansible | Tinkerbell, Metal3/Ironic |
| Failover orchestration | Custom scripts | Karmada, global load balancers |

---

*This document is a living blueprint. Update it as you implement each phase.*
