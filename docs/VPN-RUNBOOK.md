# VPN Runbook — WireGuard multi-city gateways (V1)

Operate the **additive** VPN stack. Primary/standby clusters are not required for
basic egress VPN (V1 uses a dedicated GCE VM + host WireGuard).

Design: [VPN-ARCHITECTURE.md](VPN-ARCHITECTURE.md)

## Isolation guarantees

| Touched | Untouched |
|---------|-----------|
| `vpn-gateways-gcp/` (own VPC + TF state) | `primary-cluster-gcp/`, `cloud-services-gcp/` |
| `ansible/playbooks/vpn-gateway.yml` | `ansible/playbooks/site.yml` |
| `vpn-clients/` (gitignored) | Argo ApplicationSets / `gitops/apps/*` |
| Labels `role=vpn-gateway` | Labels `cluster=primary\|standby` |

Destroying VPN never destroys k3s.

## Prerequisites

- Same GCP project / SSH key / `admin_cidr` pattern as primary
- Local tools: `terraform`, `ansible`, `wg` (wireguard-tools)
- `gcloud` auth if you manage GCP from this machine

## V1 — Deploy one city (`us`)

```bash
cd vpn-gateways-gcp
cp terraform.tfvars.example terraform.tfvars
# edit gcp_project, ssh_public_key, admin_cidr
terraform init
terraform apply

cd ..
./scripts/vpn-bootstrap.sh
```

Import `vpn-clients/us/laptop-us.conf` into the official WireGuard app and activate.

### Verify

```bash
# While tunnel is up (full tunnel default):
curl -4 ifconfig.me
# Expect the vpn_public_ip from:
terraform -chdir=vpn-gateways-gcp output -raw vpn_public_ip

ssh ubuntu@$(terraform -chdir=vpn-gateways-gcp output -raw vpn_public_ip) \
  'sudo wg show'
```

### Split tunnel (platform CIDRs only)

```bash
WG_FULL_TUNNEL=0 WG_ALLOWED_IPS=10.66.0.0/24 \
  ./scripts/generate-wg-client-config.sh us laptop
```

## Add a client (phone)

```bash
CITY=us
DIR=vpn-clients/$CITY
wg genkey | tee "$DIR/phone.privatekey" | wg pubkey >"$DIR/phone.publickey"

# Re-run ansible with an extra peer — V1 playbook is single-peer;
# for a second peer, edit /etc/wireguard/wg0.conf on the gateway
# (multi-peer ansible is Phase V2) or temporarily replace laptop keys.
```

For V1, one peer per city is enough. Document multi-peer in a follow-up.

## Tear down

```bash
terraform -chdir=vpn-gateways-gcp destroy
rm -rf vpn-clients/us   # optional — destroys local keys
```

## Second city (Phase V2 sketch)

Duplicate the stack pattern (second TF workspace or `city=hk` + `asia-east2`),
or add `for_each` over cities in Terraform. Keep separate client profiles.
Do not merge into primary Terraform.

## Troubleshooting

| Symptom | Check |
|---------|-------|
| Handshake missing | Firewall `vpn_client_cidrs` includes your current public IP; UDP 51820 |
| No internet via tunnel | `ip_forward`, NAT PostUp iface, `sudo wg show` |
| SSH timeout | `admin_cidr` stale (same lesson as k3s bootstrap) |
| Ansible unreachable | `terraform output vpn_public_ip`; refresh inventory via bootstrap |

## Security notes

- Private keys live only under `vpn-clients/` (gitignored)
- Prefer locking `vpn_client_cidrs` to your IPs; open carefully for mobile
- Gateway has `NET` forwarding + NAT — treat like an edge firewall
