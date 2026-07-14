# GCP Compute Provisioner

Creates GCE VMs via Terraform. Treats cloud VMs as bare-metal equivalents — you own the OS, install k3s yourself.

Use your own GCP account. Separate projects for dev/staging/prod are recommended.

## Projects

| Cluster | Terraform dir | Instance types (dev) |
|---------|---------------|----------------------|
| Primary | `primary-cluster-gcp/` | 1× e2-small CP + 2× e2-small workers |
| Standby | `cloud-services-gcp/` | 1× e2-small CP + 1× e2-small agent + GCS |

## Setup

```bash
# Authenticate (one-time)
gcloud auth application-default login

# Enable APIs
gcloud services enable compute.googleapis.com storage.googleapis.com --project=YOUR_PROJECT_ID
```

## Usage

```bash
# Easiest — login, create local config, deploy infra + Linkding
chmod +x scripts/gcp-*.sh
./scripts/gcp-deploy.sh

See [docs/GCP-DEPLOY.md](../docs/GCP-DEPLOY.md) for auth details and GitHub Actions comparison.

```bash
cp config/clusters.example.yaml config/clusters.yaml
cp primary-cluster-gcp/terraform.tfvars.example primary-cluster-gcp/terraform.tfvars
cp cloud-services-gcp/terraform.tfvars.example cloud-services-gcp/terraform.tfvars
# Edit gcp_project, ssh_public_key, admin_cidr in both tfvars files

./scripts/provision.sh primary
./scripts/bootstrap-cluster.sh primary
./scripts/provision.sh standby
./scripts/bootstrap-cluster.sh standby
```

## Outputs

Each project writes:

- `ansible/inventory/<cluster>-hosts.yml` — standard inventory
- `ansible/inventory/<cluster>-hosts.meta.json` — ingress IP, API host, Velero GCS creds (standby)

## Replacing with on-prem

When ready to move primary to physical hardware:

1. Bootstrap on-prem using [on-prem provisioner](../on-prem/)
2. Update `config/clusters.yaml`
3. `terraform destroy` in `primary-cluster-gcp/`

Standby can remain on GCE for hybrid DR.

## AWS alternative

AWS Terraform modules remain in `primary-cluster/` and `cloud-services/`. Switch provisioner in `config/clusters.yaml` to `aws-ec2`.
