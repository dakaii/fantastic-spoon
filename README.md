# Hybrid Bare-Metal Kubernetes Platform (AWS)

All-AWS, Terraform-managed k3s platform with dual Argo CD and fully automated failover.

## Architecture

```
Route53 (app.yourdomain.com)
  ├── PRIMARY: EC2 k3s cluster + Argo CD (active)
  └── STANDBY: EC2 k3s cluster + Argo CD (pre-deployed, idle)

Lambda Witness → Step Functions → Velero restore + Route53 failover
```

**EC2 instances = bare-metal emulation.** No QEMU needed on AWS.

See [docs/AWS-ARCHITECTURE.md](docs/AWS-ARCHITECTURE.md) for the locked design.

## Project Structure

```
├── primary-cluster/       # Terraform: EC2 primary k3s nodes + NLB
├── cloud-services/        # Terraform: EC2 standby nodes + S3 + NLB
├── shared-services/       # Terraform: Route53, Lambda witness, Step Functions
├── ansible/               # k3s bootstrap for both clusters
├── gitops/                # Dual Argo CD configs + app manifests
└── docs/
```

## Quick Start

```bash
# 1. Primary cluster
cd primary-cluster
terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" -var="admin_cidr=$(curl -s ifconfig.me)/32"
terraform output -raw ansible_inventory > ../ansible/inventory/primary-hosts.yml

# 2. Bootstrap primary k3s
cd ../ansible && ansible-playbook -i inventory/primary-hosts.yml playbooks/site.yml

# 3. Standby cluster
cd ../cloud-services
terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" -var="admin_cidr=$(curl -s ifconfig.me)/32"
terraform output -raw ansible_inventory > ../ansible/inventory/standby-hosts.yml

# 4. Bootstrap standby k3s + pre-deploy Argo CD on both clusters
ansible-playbook -i inventory/standby-hosts.yml playbooks/site.yml

# 5. Shared services (after registering a domain)
cd ../shared-services
terraform apply -var="domain_name=yourdomain.com" -var="alert_email=you@example.com"
```

## Key Design Decisions

| Decision | Choice |
|----------|--------|
| Bare-metal emulation | EC2 instances (not QEMU on AWS) |
| Argo CD | Pre-deployed on **both** primary and standby |
| Failover | Fully automated (Lambda + Step Functions + Route53) |
| Domain | Required for Phase 4 — register before DNS failover |

## Estimated Cost

| Config | ~$/month |
|--------|----------|
| Dev (1 CP + 2 workers + 2 standby) | ~$51 |
| HA (3 CP + 2 workers + 2 standby) | ~$75 |

## Documentation

- [AWS Architecture (locked design)](docs/AWS-ARCHITECTURE.md)
- [Full technical blueprint](docs/ARCHITECTURE.md)
- [Design decisions & cloud comparison](docs/DESIGN-DECISIONS.md)
