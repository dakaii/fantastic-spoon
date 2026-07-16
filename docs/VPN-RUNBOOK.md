# VPN Runbook — Consumer WireGuard city exits (V1)

Operate the **additive consumer VPN** stack (full-tunnel egress by default).
Primary/standby clusters are not required for basic egress (V1 = dedicated GCE VM
+ host WireGuard). Use the k3s Prometheus/Grafana stack to **monitor** gateways.

Product: [CONSUMER-VPN.md](CONSUMER-VPN.md)  
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

**GitHub Actions:**

```bash
gh workflow run gcp-vpn.yml -R dakaii/fantastic-spoon -f city=us
gh run watch -R dakaii/fantastic-spoon
# Download artifact wireguard-client-us → import .conf into WireGuard
```

**Local:**

```bash
cd vpn-gateways-gcp
cp terraform.tfvars.example terraform.tfvars
# edit gcp_project, ssh_public_key, admin_cidr
# optional: vpn_metrics_cidrs = ["YOUR_IP/32", "PRIMARY_NODE_NAT/32"]
terraform init
terraform apply

cd ..
./scripts/vpn-bootstrap.sh
```

Import `vpn-clients/us/laptop-us.conf` into the official WireGuard app and activate.

### Verify consumer egress

```bash
# While tunnel is up (full tunnel default):
curl -4 ifconfig.me
# Expect the vpn_public_ip from:
terraform -chdir=vpn-gateways-gcp output -raw vpn_public_ip

ssh ubuntu@$(terraform -chdir=vpn-gateways-gcp output -raw vpn_public_ip) \
  'sudo wg show; curl -s localhost:9100/metrics | grep -E "wireguard_|node_exporter_build" | head'
```

### Split tunnel (platform CIDRs only)

```bash
WG_FULL_TUNNEL=0 WG_ALLOWED_IPS=10.66.0.0/24 \
  ./scripts/generate-wg-client-config.sh us laptop
```

## Hook into platform monitoring

```bash
./scripts/vpn-prometheus-scrape-snippet.sh
```

Add the printed scrape jobs to kube-prometheus-stack (see
[MONITORING.md](MONITORING.md#consumer-vpn-gateway)). Sync GitOps monitoring so
`prometheus-rules-vpn` and the VPN Grafana dashboard are present.

Ensure `vpn_metrics_cidrs` (or `admin_cidr`) allows scrapes from wherever
Prometheus runs (often: your laptop IP for port-forward tests, or primary node
egress IPs for in-cluster scrape).

## Multi-peer clients (laptop + phone + …)

One gateway, many devices. Each device gets its own keypair and tunnel IP
(`10.66.0.2`, `.3`, …). Layout (gitignored):

```
vpn-clients/<city>/
  server.privatekey / server.publickey
  peers/
    laptop.privatekey / laptop.publickey / laptop.address
    phone.privatekey  / …
  laptop-<city>.conf
  phone-<city>.conf
```

```bash
./scripts/vpn-bootstrap.sh                 # first peer: laptop
./scripts/vpn-peer-add.sh us phone --apply # second device
./scripts/vpn-peer-list.sh us
./scripts/vpn-peer-remove.sh us phone --apply
./scripts/vpn-apply-peers.sh us            # re-push all peers to gateway
```

`--apply` runs Ansible so the gateway’s `/etc/wireguard/wg0.conf` lists every peer.
Without `--apply`, keys/configs are local only until you apply.

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
| Prometheus `VPNGatewayDown` | `vpn_metrics_cidrs` includes scraper IP; exporters `systemctl status` |

## Security notes

- Private keys live only under `vpn-clients/` (gitignored)
- Prefer locking `vpn_client_cidrs` to your IPs; open carefully for mobile
- Gateway has `NET` forwarding + NAT — treat like an edge firewall / consumer exit
- Metrics (`:9100`) are admin-only — do not expose to `0.0.0.0/0`
