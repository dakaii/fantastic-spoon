# Hybrid Bare-Metal Kubernetes Platform

A cost-efficient, production-like Kubernetes platform with local primary compute, cloud standby for automated failover, and GitOps-driven application deployment.

## What This Is

This project simulates bare-metal Kubernetes provisioning using QEMU/libvirt VMs (or real Raspberry Pi / Mac Mini hardware), runs a lightweight **k3s** cluster as the primary workload plane, and maintains a **warm cloud standby** for automated disaster recovery.

**Estimated monthly cost:** $10–25 (vs. $200–500+ for equivalent full-cloud Kubernetes)

## Architecture

```
Local (Primary)                    Cloud (Standby)
┌─────────────────────┐           ┌─────────────────────┐
│ QEMU VMs / Pi nodes │           │ t4g.nano instances  │
│ k3s HA cluster      │──Velero──▶│ k3s standby cluster │
│ Argo CD, Traefik    │  backups  │ S3, ExternalDNS     │
│ Longhorn, Prometheus│           │ Witness (Lambda)    │
└─────────────────────┘           └─────────────────────┘
         │                                    │
         └──────── Git (source of truth) ─────┘
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the full technical blueprint and [docs/DESIGN-DECISIONS.md](docs/DESIGN-DECISIONS.md) for cloud provider comparison and design choices.

## Project Structure

```
├── bare-metal-simulation/   # Terraform: QEMU/libvirt VM provisioning
├── cloud-services/          # Terraform: AWS standby + S3 backups
├── ansible/                 # Node bootstrap + k3s + add-ons
├── gitops/                  # Argo CD manifests, apps, infrastructure
├── scripts/                 # Failover, failback, health-check
└── docs/                    # Architecture documentation
```

## Quick Start

### Phase 1: Local Cluster

```bash
# 1. Provision simulated bare-metal nodes
cd bare-metal-simulation
terraform init
terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"

# 2. Update ansible inventory with node IPs
virsh domifaddr hybrid-k8s-node-1  # repeat for each node

# 3. Bootstrap k3s cluster
cd ../ansible
ansible-playbook playbooks/site.yml
```

### Phase 2: Cloud Standby

```bash
cd cloud-services
terraform init
terraform apply \
  -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var="admin_cidr=$(curl -s ifconfig.me)/32"
```

### Phase 3: GitOps

```bash
# Apply root Argo CD application
kubectl apply -f gitops/argocd/applications/root-app.yaml

# Register cloud standby cluster
kubectl apply -f gitops/argocd/clusters/cloud-standby.yaml
```

### Phase 4: Test Failover

```bash
# Simulate local cluster failure
scripts/health-check.sh   # runs continuously via witness
scripts/failover.sh         # or triggered automatically

# Restore when local recovers
scripts/failback.sh
```

## Skills You'll Learn

- Multi-project Terraform (libvirt + AWS providers)
- Ansible automation for k3s bootstrap
- GitOps with Argo CD (ApplicationSets, multi-cluster)
- Disaster recovery (Velero, automated DNS failover)
- Hybrid cloud cost optimization
- Edge computing (Traefik on ARM / Raspberry Pi)

## Is This a Good Cloud Engineering Project?

Yes. This covers infrastructure as code, hybrid architecture, high availability, GitOps, observability, and bare-metal concepts — all skills used in production cloud engineering roles. A documented, working implementation is strong portfolio material.

## License

MIT
