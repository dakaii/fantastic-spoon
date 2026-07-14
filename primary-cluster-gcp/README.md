# Primary Cluster — GCP Compute Engine

Provisions GCE VMs for the primary k3s cluster.

## Prerequisites

1. [GCP account](https://console.cloud.google.com) (your own Google account)
2. Create a **project** (recommended: separate projects for dev/staging/prod)
3. Enable APIs:
   ```bash
   gcloud services enable compute.googleapis.com --project=YOUR_PROJECT_ID
   ```
4. Authenticate Terraform:
   ```bash
   gcloud auth application-default login
   ```

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit gcp_project, ssh_public_key, admin_cidr

terraform init
terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory/primary-hosts.yml
../scripts/bootstrap-cluster.sh primary
```

## Cost estimate (dev: 1 CP + 2 workers)

| Resource | Type | ~$/month |
|----------|------|----------|
| Control plane | e2-small | ~$12 |
| Workers (×2) | e2-small | ~$24 |
| **Total** | | **~$36** |

e2-micro is free-tier eligible but too small for k3s + addons (primary or standby).
Use e2-medium for the control plane and e2-small (or larger) for workers and standby.

See [docs/GCP-ARCHITECTURE.md](../docs/GCP-ARCHITECTURE.md).
