# VPN Gateways (GCP) — Additive WireGuard exits

Isolated Terraform stack for **multi-city WireGuard gateways**.

- **Does not** modify `primary-cluster-gcp/` or `cloud-services-gcp/`
- **Does not** join k3s (V1 = host WireGuard on a dedicated VM)
- **Does not** use `labels.cluster=primary|standby` (safe for inventory scripts)

Design: [docs/VPN-ARCHITECTURE.md](../docs/VPN-ARCHITECTURE.md)  
Operate: [docs/VPN-RUNBOOK.md](../docs/VPN-RUNBOOK.md)

## Quick start

```bash
cd vpn-gateways-gcp
cp terraform.tfvars.example terraform.tfvars
# edit: gcp_project, ssh_public_key, admin_cidr (same as primary)

terraform init
terraform apply

# Generate keys + configure server + write client config
cd ..
./scripts/vpn-bootstrap.sh
```

Destroy anytime (primary/standby untouched):

```bash
terraform -chdir=vpn-gateways-gcp destroy
```

## Outputs

| Output | Use |
|--------|-----|
| `vpn_public_ip` | WireGuard Endpoint in client `.conf` |
| `ansible_inventory` | Written by bootstrap to `ansible/inventory/vpn-hosts.yml` |
