# Consumer VPN — Product & Architecture

**Status:** V1 data plane exists (full-tunnel WireGuard exit). This doc locks the
**product direction**: a personal/portfolio consumer VPN built **on top of** the
portable k3s platform, monitored with the existing Prometheus/Grafana stack.

Design detail: [VPN-ARCHITECTURE.md](VPN-ARCHITECTURE.md)  
Operate: [VPN-RUNBOOK.md](VPN-RUNBOOK.md)  
Monitor: [MONITORING.md](MONITORING.md#consumer-vpn-gateway)

---

## 1. What we are building

A **consumer-style VPN**: connect with the official WireGuard app → your public
egress IP becomes the gateway’s GCP IP → browse the internet through our exit.

| In scope (product) | Out of scope (for now) |
|--------------------|------------------------|
| Full-tunnel egress (`0.0.0.0/0`) | Custom mobile/desktop VPN app |
| Multi-city exits (regions as “cities”) | Billing, subscriptions, App Store |
| Stock WireGuard clients | “Bypass geo-blocks” marketing |
| Monitor gateways via Prometheus/Grafana | Enterprise IdP / SSO |
| Keep portable k3s platform for ops | Replacing Traefik for web apps |

Resume framing:

> Built a WireGuard consumer VPN (full-tunnel city exits) beside a portable
> multi-cluster k3s platform — Terraform + Ansible gateways, GitOps, Prometheus
> monitoring of peer health and egress capacity.

---

## 2. Traefik vs VPN (do not confuse them)

| | **WireGuard gateway** | **Traefik** |
|--|----------------------|-------------|
| Job | Move **packets** (L3/L4) through an encrypted tunnel + NAT to the internet | Route **HTTP** to *your* cluster apps |
| End-user browsing `google.com` | Yes — through WG + SNAT | No |
| Your app / Grafana / Argo | Optional private path later | Yes — Ingress / IngressRoute |
| Needed for consumer VPN egress? | **Required** | **Not on the egress path** |

```
Consumer browse path (no Traefik):
  Device → WireGuard → VPN gateway NAT → Internet

Platform manage path (Traefik stays):
  You → (VPN or public LB) → Traefik → Argo / Grafana / apps
```

**Keep Traefik** to operate the platform you use to *run and monitor* the VPN.
End users of the VPN do not need Traefik for general web browsing.

---

## 3. Additive layout (unchanged principle)

```
vpn-gateways-gcp/     ← consumer exit VMs (own VPC; safe to destroy alone)
ansible wireguard-node ← WG + NAT + metrics exporters
primary-cluster-gcp/  ← k3s + Traefik + Prometheus/Grafana (ops plane)
shared-services-gcp/  ← platform DNS failover (orthogonal to VPN)
```

Destroying VPN never destroys k3s. k3s never has to be up for basic egress
(V1 host WireGuard). Monitoring *reuse* means scraping gateway exporters into
the **existing** Prometheus on primary when you want dashboards/alerts there.

---

## 4. Traffic modes

| Mode | AllowedIPs | Use |
|------|------------|-----|
| **Full tunnel (default)** | `0.0.0.0/0, ::/0` | Consumer VPN — all device traffic via exit |
| **Split tunnel** | e.g. `10.66.0.0/24` | Lab / platform-only |
| **Platform private** | Cluster CIDRs, no SNAT story | Interview demo only |

V1 already enables IP forwarding + `MASQUERADE` on the gateway (`PostUp` in
`ansible/roles/wireguard-node`). Full tunnel is the **product default**.

---

## 5. Monitoring (reuse what we built)

Gateways are **outside** k3s (dedicated VPC). We still monitor them with the
platform stack:

1. **On the gateway (Ansible):** `node_exporter` + WireGuard **textfile** metrics (`wg show dump`)
2. **Firewall:** TCP `:9100` open only to `admin_cidr` / `vpn_metrics_cidrs`
3. **Prometheus on primary:** additional scrape job `vpn-gateway` → `vpn_public_ip:9100`
4. **GitOps:** `PrometheusRule` + Grafana dashboard under
   `gitops/infrastructure/primary/monitoring/`

```bash
# After vpn-bootstrap.sh
./scripts/vpn-prometheus-scrape-snippet.sh
# Apply scrape config to kube-prometheus-stack (see MONITORING.md)
```

Alerts (once scraped):

| Alert | Meaning |
|-------|---------|
| `VPNGatewayDown` | `up{job="vpn-gateway"} == 0` |
| `WireGuardInterfaceDown` | WG interface missing |
| `WireGuardPeerHandshakeStale` | No recent handshake |

---

## 6. Roadmap

| Phase | Outcome |
|-------|---------|
| **V1** (done) | Single-city full tunnel; exporters + scrape/alerts docs |
| **V1.1** (this) | **Multi-peer** — laptop + phone + friends on one city exit |
| **V2** | Second city; switch profile → different egress IP |
| **V3** | Rate/abuse notes; DNS names `vpn-us.<domain>`; optional Traefik allowlists |

---

## 7. Security & abuse (honest constraints)

- Personal / portfolio use first — cloud ToS and bandwidth matter.
- Lock `vpn_client_cidrs` to your IPs when possible; open carefully for mobile.
- Never commit keys under `vpn-clients/` (gitignored).
- Metrics ports are **not** public; scrape from admin or primary egress CIDRs only.
- Full-tunnel NAT makes the gateway an **edge router** — treat SSH and WG like production edge.

---

## 8. Quick start

```bash
# 1. Gateway VM
cd vpn-gateways-gcp && cp terraform.tfvars.example terraform.tfvars
# set gcp_project, ssh_public_key, admin_cidr
terraform init && terraform apply

# 2. WireGuard + exporters + first peer (laptop)
cd .. && ./scripts/vpn-bootstrap.sh

# 3. Import vpn-clients/us/laptop-us.conf → WireGuard app → Activate
#    Or CLI (no GUI): ./scripts/vpn.sh up && ./scripts/vpn.sh ip
curl -4 ifconfig.me   # expect terraform output vpn_public_ip

# 4. Add more devices
./scripts/vpn-peer-add.sh us phone --apply
./scripts/vpn-peer-list.sh us

# 5. Hook metrics into platform Prometheus
./scripts/vpn-prometheus-scrape-snippet.sh
# follow printed instructions / docs/MONITORING.md
```

GitHub Actions:

```bash
gh workflow run gcp-vpn.yml -R dakaii/fantastic-spoon -f city=us
gh workflow run gcp-vpn-destroy.yml -R dakaii/fantastic-spoon   # VPN only
```
