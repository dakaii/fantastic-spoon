# Cloud Services — GCP Standby + GCS Backups

Provisions the standby k3s cluster on GCE, a GCS bucket for Velero, and HMAC keys for S3-compatible backup access.

## Prerequisites

Same as [primary-cluster-gcp](../primary-cluster-gcp/README.md). Enable Storage API:

```bash
gcloud services enable storage.googleapis.com --project=YOUR_PROJECT_ID
```

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit gcp_project, ssh_public_key, admin_cidr

terraform init
terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory/standby-hosts.yml
terraform output -json cluster_meta > ../ansible/inventory/standby-hosts.meta.json
../scripts/bootstrap-cluster.sh standby
```

## Cost estimate (2× e2-small standby)

| Resource | Type | ~$/month |
|----------|------|----------|
| Standby nodes (×2) | e2-small | ~$12–14 |
| GCS backups (100 GB) | Standard | ~$2 |
| **Total** | | **~$14–16** |

`e2-micro` is free-tier eligible but too small for k3s + Traefik + Argo CD bootstrap
(apt/API timeouts). Use `e2-small` or larger.

See [docs/GCP-ARCHITECTURE.md](../docs/GCP-ARCHITECTURE.md).
