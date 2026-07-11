# Portable Architecture — Swap EC2 for On-Prem Without Rewriting the Platform

This project is structured in **layers**. Only the bottom layer (provisioning) changes when you move from EC2 to on-prem hardware. Everything above it stays the same.

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 4: Failover        shared-services/ (AWS-only)       │
│                           Route53, Lambda witness            │
├─────────────────────────────────────────────────────────────┤
│  Layer 3: GitOps          gitops/                           │
│                           Argo CD, apps, ApplicationSets     │
├─────────────────────────────────────────────────────────────┤
│  Layer 2: Bootstrap       ansible/                          │
│                           k3s, Cilium, Traefik, Argo CD      │
├─────────────────────────────────────────────────────────────┤
│  Layer 1: Provisioning    ← SWAP THIS LAYER                 │
│                           aws-ec2 | libvirt | on-prem        │
│                           Output: Ansible inventory + meta   │
└─────────────────────────────────────────────────────────────┘
```

## The Contract: Ansible Inventory

Every provisioner — EC2, libvirt, or on-prem — must produce an inventory file matching this schema. Ansible, GitOps, and failover scripts only read this file.

```yaml
all:
  vars:
    # Required
    ansible_user: ubuntu
    cluster_name: primary          # primary | standby
    cluster_profile: primary       # primary | standby (controls addon set)
    provisioner: aws-ec2           # aws-ec2 | libvirt | on-prem

    # Optional (used by failover / ingress)
    ingress_host: ""               # NLB DNS, or Traefik IP/hostname
    k3s_api_host: ""               # First control plane IP

    # Bootstrap
    k3s_version: "v1.29.5+k3s1"
    ansible_ssh_common_args: "-o StrictHostKeyChecking=no"

  children:
    k3s_server:
      hosts:
        <hostname>:
          ansible_host: <ip-or-hostname>
          node_role: server
    k3s_agent:
      hosts:
        <hostname>:
          ansible_host: <ip-or-hostname>
          node_role: agent
```

See [ansible/inventory/README.md](../ansible/inventory/README.md) for the full spec and examples.

## Supported Provisioners

| Provisioner | Use case | Terraform dir | On-prem ready? |
|-------------|----------|---------------|----------------|
| **aws-ec2** | All-in-AWS, cloud learning | `primary-cluster/`, `cloud-services/` | No (cloud VMs) |
| **libvirt** | Free local simulation (QEMU/KVM) | `bare-metal-simulation/` | Simulates on-prem |
| **on-prem** | Real hardware (Pi, Mac Mini, rack servers) | None — manual inventory | Yes |

Register and switch provisioners in `config/clusters.yaml`.

## Switching Primary from EC2 to On-Prem

You only change Layer 1. Layers 2–4 run unchanged.

### Before (EC2)

```yaml
# config/clusters.yaml
primary:
  provisioner: aws-ec2
  terraform_dir: primary-cluster
  inventory: ansible/inventory/primary-hosts.yml
  profile: primary
```

```bash
./scripts/provision.sh primary
./scripts/bootstrap-cluster.sh primary
```

### After (on-prem)

```yaml
# config/clusters.yaml
primary:
  provisioner: on-prem
  inventory: ansible/inventory/on-prem.primary.yml
  profile: primary
```

```bash
# 1. Prepare each physical server (once)
./provisioners/on-prem/prepare-node.sh 192.168.1.10 cp-1 server

# 2. Fill in inventory with your server IPs
cp provisioners/on-prem/inventory.primary.example.yml ansible/inventory/on-prem.primary.yml

# 3. Bootstrap — same Ansible playbook as EC2
./scripts/bootstrap-cluster.sh primary
```

Destroy EC2 primary when ready: `cd primary-cluster && terraform destroy`

**Unchanged:** Ansible roles, GitOps manifests, Argo CD config, app deployments, Velero backup logic.

## Hybrid Configurations

Mix provisioners per cluster — common in production:

| Primary | Standby | Failover |
|---------|---------|----------|
| on-prem | AWS EC2 | Primary dies → cloud takes over |
| libvirt (dev) | AWS EC2 | Local dev + real cloud DR |
| AWS EC2 | AWS EC2 | Full cloud (current default) |
| on-prem | on-prem (second site) | DNS failover between sites |

Example hybrid config:

```yaml
primary:
  provisioner: on-prem
  inventory: ansible/inventory/on-prem.primary.yml
  profile: primary

standby:
  provisioner: aws-ec2
  terraform_dir: cloud-services
  inventory: ansible/inventory/standby-hosts.yml
  profile: standby
```

Layer 4 (`shared-services/`) stays AWS for Route53 + Lambda witness even when primary is on-prem.

## What Each Layer Owns

| Layer | Owns | Does NOT own |
|-------|------|------------|
| Provisioning | VMs/servers, networks, NLBs, SSH access | k3s, apps, DNS failover |
| Ansible | OS prep, k3s install, Helm add-ons | VM creation |
| GitOps | App manifests, Argo CD, sync policies | Infrastructure |
| Failover | Route53, Lambda, Step Functions | Cluster bootstrap |

## File Map

```
config/clusters.yaml          ← single switch for provisioner per cluster
scripts/provision.sh          ← Layer 1 entry point
scripts/bootstrap-cluster.sh  ← Layer 2 entry point
ansible/inventory/            ← contract between Layer 1 and 2
provisioners/                 ← docs + templates per provider
primary-cluster/              ← aws-ec2 primary
cloud-services/               ← aws-ec2 standby + S3
bare-metal-simulation/        ← libvirt primary (local)
provisioners/on-prem/           ← on-prem templates + prepare script
```

## Migration Checklist: EC2 → On-Prem

1. [ ] Provision on-prem servers (Ubuntu 24.04, ARM or x86)
2. [ ] Run `prepare-node.sh` on each node (kernel modules, packages, swap off)
3. [ ] Create `ansible/inventory/on-prem.primary.yml` from example
4. [ ] Update `config/clusters.yaml` → `provisioner: on-prem`
5. [ ] Run `./scripts/bootstrap-cluster.sh primary`
6. [ ] Verify: `kubectl get nodes`
7. [ ] Point Argo CD / GitOps at new cluster (same manifests)
8. [ ] Update Velero backup location if needed
9. [ ] Update Route53 health check to ping on-prem ingress
10. [ ] Destroy EC2 primary: `terraform destroy` in `primary-cluster/`
