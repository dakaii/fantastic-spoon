# Hybrid Bare-Metal Kubernetes Platform

Portable k3s platform — swap EC2 for on-prem hardware without rewriting Ansible or GitOps.

## Architecture

```
Layer 4  shared-services/     Route53, Lambda witness (AWS)
Layer 3  gitops/               Argo CD, apps
Layer 2  ansible/              k3s bootstrap (same for all providers)
Layer 1  provisioners/         aws-ec2 | libvirt | on-prem  ← swap here
```

**Switch primary from EC2 to Raspberry Pi:** change one line in `config/clusters.yaml`, run bootstrap again. See [docs/PORTABLE-ARCHITECTURE.md](docs/PORTABLE-ARCHITECTURE.md).

## Quick Start (AWS EC2)

```bash
cp config/clusters.example.yaml config/clusters.yaml
cp primary-cluster/terraform.tfvars.example primary-cluster/terraform.tfvars
# edit terraform.tfvars

chmod +x scripts/*.sh
./scripts/phase1-primary.sh
./scripts/phase2-standby.sh
```

## Quick Start (On-Prem Primary)

```bash
# config/clusters.yaml
primary:
  provisioner: on-prem
  inventory: ansible/inventory/on-prem.primary.yml
  profile: primary

cp provisioners/on-prem/inventory.primary.example.yml ansible/inventory/on-prem.primary.yml
# edit IPs, run prepare-node.sh on each server

./scripts/bootstrap-cluster.sh primary
```

## Project Structure

```
config/clusters.yaml           ← switch provisioner per cluster
provisioners/                  ← aws-ec2, libvirt, on-prem
primary-cluster/               ← aws-ec2 primary Terraform
cloud-services/                ← aws-ec2 standby + S3
bare-metal-simulation/         ← libvirt local VMs
ansible/                       ← provider-agnostic bootstrap
gitops/                        ← provider-agnostic apps
shared-services/               ← AWS failover layer
scripts/provision.sh           ← Layer 1 entry point
scripts/bootstrap-cluster.sh   ← Layer 2 entry point
```

## Documentation

- [Portable architecture — swap EC2 for on-prem](docs/PORTABLE-ARCHITECTURE.md)
- [Phase 1 Runbook — Primary cluster](docs/PHASE-1-RUNBOOK.md)
- [Phase 2 Runbook — Standby + backups](docs/PHASE-2-RUNBOOK.md)
- [AWS Architecture](docs/AWS-ARCHITECTURE.md)
- [On-prem provisioner](provisioners/on-prem/README.md)
