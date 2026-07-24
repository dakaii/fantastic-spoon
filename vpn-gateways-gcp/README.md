# VPN Gateways (GCP) — Consumer WireGuard exits

Isolated Terraform stack for **consumer VPN city exits** (full-tunnel WireGuard).

- **Does not** modify `primary-cluster-gcp/` or `cloud-services-gcp/`
- **Does not** join k3s (V1 = host WireGuard on a dedicated VM)
- **Does not** use `labels.cluster=primary|standby` (safe for inventory scripts)
- Exposes `node_exporter` on `:9100` for platform Prometheus (firewall-restricted)

Product: [docs/CONSUMER-VPN.md](../docs/CONSUMER-VPN.md)  
Design: [docs/VPN-ARCHITECTURE.md](../docs/VPN-ARCHITECTURE.md)  
Operate: [docs/VPN-RUNBOOK.md](../docs/VPN-RUNBOOK.md)  
Interview demo: [docs/PORTFOLIO-DEMO.md](../docs/PORTFOLIO-DEMO.md)

**Cities:** `us` (us-central1) and `hk` (asia-east2). Each city = separate GCS TF state
(`vpn-gateways-gcp/<city>/…`). Prefer `VPN_CITY=hk ./scripts/gcp-deploy.sh vpn` or GHA `city=hk`.

## Quick start

```bash
# Recommended (writes tfvars + region map + state sync)
VPN_CITY=us GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-deploy.sh vpn

# Second city (does not replace us)
VPN_CITY=hk GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-deploy.sh vpn

# Or manual:
cd vpn-gateways-gcp
cp terraform.tfvars.example terraform.tfvars
# edit: gcp_project, ssh_public_key, admin_cidr, city/region
terraform init && terraform apply
cd .. && ./scripts/vpn-bootstrap.sh
```

Destroy one city (primary/standby untouched):

```bash
VPN_CITY=us GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-vpn-destroy-ci.sh
# or: gh workflow run gcp-vpn-destroy.yml -f city=us
```

## Outputs

| Output | Use |
|--------|-----|
| `vpn_public_ip` | WireGuard Endpoint in client `.conf` |
| `vpn_metrics_url` | Prometheus scrape target (`IP:9100`) |
| `ansible_inventory` | Written by bootstrap to `ansible/inventory/vpn-hosts-<city>.yml` |
