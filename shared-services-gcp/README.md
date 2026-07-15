# Shared Services — GCP Failover Layer (Phase 4)

Cloud Function witness, Cloud Workflows (notify stubs), and optional Cloud DNS
primary/backup routing.

Operator guide: [docs/PHASE-4-RUNBOOK.md](../docs/PHASE-4-RUNBOOK.md)

## Prerequisites

1. Apply `primary-cluster-gcp/` and `cloud-services-gcp/` first (local state paths used as remote_state)
2. Enable APIs (includes Gen2):
   ```bash
   GCP_PROJECT=YOUR_PROJECT_ID ./scripts/gcp-enable-apis.sh
   ```
3. Allow witness to reach primary `:6443` (lab):
   ```hcl
   # primary-cluster-gcp/terraform.tfvars
   k3s_api_source_ranges = ["0.0.0.0/0"]
   ```
4. Domain is **optional** for the witness; **required** for Cloud DNS failover

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit gcp_project; leave domain_name="" for witness-only
# Set domain_name when NS can point at Cloud DNS

terraform init
terraform apply

# Or:
./scripts/gcp-deploy.sh failover
```

## Components

| AWS equivalent | GCP service | Status |
|----------------|-------------|--------|
| Lambda witness | Cloud Function Gen2 + Scheduler | Implemented |
| Step Functions | Cloud Workflows | Notify + Velero/Argo **stubs** |
| DynamoDB state | Firestore | Implemented |
| SNS alerts | Pub/Sub | Implemented |
| Route53 failover | Cloud DNS primary/backup | Gated on `domain_name` |

Manual app activation: `./scripts/failover-gcp.sh activate-apps`

See [docs/GCP-ARCHITECTURE.md](../docs/GCP-ARCHITECTURE.md).
