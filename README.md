# Hybrid Bare-Metal Kubernetes Platform

Portable k3s platform — swap GCE for on-prem hardware without rewriting Ansible or GitOps.

## Architecture

```
Layer 4  shared-services-gcp/  Cloud DNS, Cloud Function witness (GCP)
Layer 3  gitops/                Argo CD, apps
Layer 2  ansible/               k3s bootstrap (same for all providers)
Layer 1  provisioners/          gcp-compute | aws-ec2 | libvirt | on-prem  ← swap here
```

**Switch primary from GCE to Raspberry Pi:** change one line in `config/clusters.yaml`, run bootstrap again. See [docs/PORTABLE-ARCHITECTURE.md](docs/PORTABLE-ARCHITECTURE.md).

## Quick Start (GCP — default)

```bash
cp config/clusters.example.yaml config/clusters.yaml
cp primary-cluster-gcp/terraform.tfvars.example primary-cluster-gcp/terraform.tfvars
cp cloud-services-gcp/terraform.tfvars.example cloud-services-gcp/terraform.tfvars
# edit terraform.tfvars (gcp_project, ssh_public_key, admin_cidr)

gcloud auth application-default login

chmod +x scripts/gcp-*.sh scripts/phase*.sh
./scripts/gcp-deploy.sh          # login → config → infra → Linkding (recommended)

# Or step by step — see docs/GCP-DEPLOY.md
# ./scripts/gcp-deploy.sh auth
# ./scripts/gcp-deploy.sh init
# ./scripts/gcp-deploy.sh infra
# ./scripts/gcp-deploy.sh apps

# Deploy apps via Argo CD (after cluster bootstrap)
kubectl apply -f gitops/argocd/applications/root-app.yaml
# Linkding bookmarks app: gitops/apps/linkding/
```

Use your own GCP account — separate projects per environment are supported. See [docs/GCP-ARCHITECTURE.md](docs/GCP-ARCHITECTURE.md).

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

## Quick Start (AWS — alternative)

```bash
# config/clusters.yaml — set provisioner: aws-ec2, terraform_dir: primary-cluster / cloud-services
cp primary-cluster/terraform.tfvars.example primary-cluster/terraform.tfvars
./scripts/phase1-primary.sh
```

## Project Structure

```
config/clusters.yaml              ← switch provisioner per cluster
provisioners/                     ← gcp-compute, aws-ec2, libvirt, on-prem
primary-cluster-gcp/              ← GCP primary Terraform (default)
cloud-services-gcp/               ← GCP standby + GCS
shared-services-gcp/              ← GCP failover layer
primary-cluster/                  ← AWS alternative
cloud-services/                   ← AWS alternative
bare-metal-simulation/            ← libvirt local VMs
ansible/                          ← provider-agnostic bootstrap
gitops/                           ← provider-agnostic apps
shared-services/                  ← AWS failover layer
scripts/provision.sh              ← Layer 1 entry point
scripts/bootstrap-cluster.sh      ← Layer 2 entry point
```

## Documentation

- [GCP Architecture (default)](docs/GCP-ARCHITECTURE.md)
- [GCP Deploy guide — local scripts vs GitHub Actions](docs/GCP-DEPLOY.md)
- [Monitoring — Prometheus alerts + Grafana](docs/MONITORING.md)
- [Portable architecture — swap cloud for on-prem](docs/PORTABLE-ARCHITECTURE.md)
- [Phase 1 Runbook — Primary cluster](docs/PHASE-1-RUNBOOK.md)
- [Phase 2 Runbook — Standby + backups](docs/PHASE-2-RUNBOOK.md)
- [AWS Architecture (alternative)](docs/AWS-ARCHITECTURE.md)
- [GCP Compute provisioner](provisioners/gcp-compute/README.md)
- [On-prem provisioner](provisioners/on-prem/README.md)
