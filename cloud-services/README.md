# Cloud Services (Terraform — AWS)

Provisions the cloud standby cluster, backup storage, and IAM for Velero.

## Resources Created

| Resource | Purpose |
|----------|---------|
| EC2 instances (×2 t4g.nano) | k3s standby nodes (tainted `standby=true:NoSchedule`) |
| S3 bucket | Velero backups + optional TF remote state |
| IAM user + policy | Velero S3 access |
| VPC + subnet + SG | Minimal networking for standby |

## Usage

```bash
terraform init
terraform plan \
  -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var="admin_cidr=$(curl -s ifconfig.me)/32"
terraform apply \
  -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var="admin_cidr=$(curl -s ifconfig.me)/32"
```

## Post-Apply

1. Register standby cluster in Argo CD (see `gitops/argocd/clusters/cloud-standby.yaml`).
2. Store Velero credentials in External Secrets (from sensitive outputs).
3. Configure Velero on both clusters pointing to the S3 bucket.

See [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for the full platform design.
