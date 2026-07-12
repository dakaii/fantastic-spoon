# Shared Services — GCP Failover Layer

Cloud Function witness, Cloud Workflows failover, and Cloud DNS routing for automated DR.

## Prerequisites

1. Apply `primary-cluster-gcp/` and `cloud-services-gcp/` first
2. Enable APIs:
   ```bash
   gcloud services enable \
     dns.googleapis.com \
     cloudfunctions.googleapis.com \
     cloudscheduler.googleapis.com \
     workflows.googleapis.com \
     firestore.googleapis.com \
     pubsub.googleapis.com \
     --project=YOUR_PROJECT_ID
   ```
3. Register a domain before configuring Cloud DNS failover (Phase 4)

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# Edit gcp_project; set domain_name when ready

terraform init
terraform apply
```

## Components

| AWS equivalent | GCP service |
|----------------|-------------|
| Lambda witness | Cloud Function (Gen2) + Cloud Scheduler |
| Step Functions | Cloud Workflows |
| DynamoDB state | Firestore |
| SNS alerts | Pub/Sub |
| Route53 failover | Cloud DNS primary/backup routing |

See [docs/GCP-ARCHITECTURE.md](../docs/GCP-ARCHITECTURE.md).
