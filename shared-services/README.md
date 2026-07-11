# Shared Services — Route53, Lambda Witness, Step Functions

Automated failover infrastructure. Deploy **after** primary and standby clusters are running.

## Resources

| Resource | Purpose |
|----------|---------|
| Route53 failover records | DNS cutover primary → standby (requires domain) |
| Route53 health check | Monitors primary NLB |
| Lambda witness | Polls k3s API every 1 min, triggers failover |
| DynamoDB | Tracks consecutive failure count |
| Step Functions | Orchestrates failover workflow |
| SNS | Email/alert notifications |

## Prerequisites

1. Primary cluster deployed (`../primary-cluster/`)
2. Standby cluster deployed (`../cloud-services/`)
3. Domain registered (for Route53 — optional until Phase 4)

## Usage

```bash
# Without domain (witness only):
terraform init
terraform apply \
  -var="alert_email=you@example.com"

# With domain (full DNS failover):
terraform apply \
  -var="domain_name=yourdomain.com" \
  -var="app_subdomain=app" \
  -var="alert_email=you@example.com"
```

After apply with a domain, update your registrar's NS records to the `route53_name_servers` output.

See [docs/AWS-ARCHITECTURE.md](../docs/AWS-ARCHITECTURE.md) for the full failover design.
