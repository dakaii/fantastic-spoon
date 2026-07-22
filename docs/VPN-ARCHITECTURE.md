# Multi-Region WireGuard VPN Gateways — Design Doc

**Status:** V1 implemented (additive host WireGuard, **full-tunnel consumer exit**)  
**Goal:** Highly available, multi-city WireGuard **consumer VPN** exits (stock clients),
deployed beside the portable k3s platform and monitored with existing Prometheus/Grafana.
No custom VPN app or billing in V1–V2.

**Product overview:** [CONSUMER-VPN.md](CONSUMER-VPN.md)  
**Operate:** [VPN-RUNBOOK.md](VPN-RUNBOOK.md)  
**Interview demo:** [PORTFOLIO-DEMO.md](PORTFOLIO-DEMO.md)

---

## Product vs platform (read this first)

| Plane | Role |
|-------|------|
| **Consumer VPN** | Full-tunnel WireGuard → gateway NAT → internet (end-user browsing) |
| **k3s + Traefik** | Operate/monitor the platform (Argo, Grafana, apps). **Not** on the browse path |

End users do **not** go through Traefik to visit random websites. You still keep
Traefik to manage the control/ops plane. Details: [CONSUMER-VPN.md](CONSUMER-VPN.md).

---

## 1. Why this (and why not)

### Portfolio / career reality

| Question | Honest answer |
|----------|---------------|
| Is this a good showcase? | **Yes** — consumer VPN data plane **plus** portable k3s ops/monitoring is stronger than “K8s only” or “WG script only.” |
| Do lots of people build this for jobs? | Lots build “K8s on a cloud.” Fewer show **self-managed multi-region egress + GitOps + Prometheus on the exit path**. |
| What do employers hire for? | Terraform, networking, Traefik/ingress, GitOps, observability, security boundaries. Stock WireGuard clients are fine. |
| What not to do (yet) | Custom mobile app; billing; “bypass geo-blocks” framing; ripping out Traefik. |

This project is **additive** to fantastic-spoon. It does not replace primary/standby, Traefik, Argo CD, or Velero — the VPN rides beside them; monitoring scrapes into the existing stack.

### Product framing (resume one-liner)

> Built a full-tunnel multi-city WireGuard consumer VPN beside a portable k3s platform — Terraform/Ansible gateways, stock clients, Prometheus/Grafana for peer and host health.

---

## 2. Relationship to existing fantastic-spoon

```
Layer 4  shared-services-gcp/     DNS + witness failover (platform public apps)
Layer 3  gitops/                   Argo CD apps  ← ADD: wireguard chart / Application
Layer 2  ansible/                  k3s + addons  ← OPTIONAL: WG sysctl / modules
Layer 1  provisioners/             GCE nodes     ← ADD: labeled VPN gateway nodes
                                                   (same or extra regions)
```

| Existing capability | VPN uses it for |
|---------------------|-----------------|
| Primary + standby k3s | Control plane / GitOps home; optional secondary exit later |
| Traefik | Ops plane HTTP routing (apps/admin). Optional later: VPN-only IngressRoutes. **Not** used for consumer internet egress. |
| Cilium / NetworkPolicy | Lock gateway namespace; restrict who can talk to WG |
| Argo CD | Deploy & sync gateway chart; multi-cluster if desired |
| Velero | Backup WG ConfigMaps/Secrets (keys: careful — prefer sealed/external) |
| Terraform (primary / cloud-services) | Extra instances or instance groups tagged `role=vpn-gateway` |
| Phase 4 DNS failover | Orthogonal: public app failover ≠ VPN peer failover |

**Non-goals for v1–v2**

- Custom WireGuard GUI/mobile client / App Store
- Billing, multi-tenant SaaS accounts
- Replacing Cloudflare/Tailscale for company SSO
- Using Traefik as a forward proxy for arbitrary websites

**Goals for consumer product (incremental)**

- Full-tunnel exit as default; multi-city profiles; scrape metrics into platform Prometheus

---

## 3. Target architecture

### 3.1 Logical view

```
┌──────────────────┐     WireGuard (UDP 51820)
│  Your device     │ ──────────────────────────────────────────┐
│  (stock client)  │                                            │
│  peer profiles:  │     ┌──────────────────────────────────────▼─────────────────┐
│   • us-central1  │     │              fantastic-spoon (k3s)                    │
│   • asia-east2   │     │  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │
│   • europe-west1 │─────▶│ │ GW us-c1   │  │ GW asia-e2 │  │ GW eu-w1   │    │
│                  │     │  │ (exit A)    │  │ (exit B)    │  │ (exit C)    │    │
└──────────────────┘     │  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘    │
                         │         │  SNAT egress   │                │           │
                         │         ▼                ▼                ▼           │
                         │              Public Internet / AI APIs / etc.         │
                         │  Traefik (ClusterIP / internal only) ← VPN users only │
                         └───────────────────────────────────────────────────────┘
```

### 3.2 Client UX (no custom app)

Ship **one WireGuard config per city** (or a small generator script):

- `fantastic-us.conf` → endpoint `vpn-us.example.com:51820` (or raw GCE NAT IP)
- `fantastic-hk.conf` → endpoint `vpn-hk.example.com:51820`
- `fantastic-eu.conf` → …

Switching cities = activate a different tunnel in the official WireGuard app.  
HA within a city = multiple endpoints / DNS round-robin / documented failover peer (v1.1).

### 3.3 Traffic modes

| Mode | Behavior | Product default |
|------|----------|-----------------|
| **Full tunnel** | `0.0.0.0/0`, `::/0` via WG + SNAT | **Yes (V1)** — consumer VPN |
| **Split tunnel** | Only selected CIDRs via WG | Optional (`WG_FULL_TUNNEL=0`) |
| **Private platform only** | Reach Traefik/Argo/Grafana; no internet browse | Optional interview demo |

Client generator defaults to full tunnel (`WG_FULL_TUNNEL=1`).

### 3.4 Data-plane choices (lock for v1)

| Decision | Choice | Why |
|----------|--------|-----|
| VPN protocol | **WireGuard** | Simple, performant, interview-friendly |
| Where WG runs | **Dedicated GCE node(s) per region** labeled `role=vpn-gateway`, joined as k3s agents **or** standalone VMs with Ansible | Cleaner than sharing CP; avoids e2-small starvation |
| In-cluster packaging | Helm chart + Argo Application under `gitops/` | Matches platform story |
| Key management | Ansible/sops/age or GCP Secret Manager → K8s Secret | Don’t commit private keys |
| Client | Official WireGuard (macOS/iOS/Android/Linux) | No app to build |
| Multi-city | **One (or more) gateway node per GCP region** | “Cities” = regions |

**GCP regions for an MVP city list** (cheap / free-aware):

| Profile name | Region | Notes |
|--------------|--------|-------|
| `us` | `us-central1` | Co-locate with current primary |
| `hk` | `asia-east2` | Second city (your example) |
| `eu` | `europe-west1` | Third city (phase later) |

Multi-city exits are **optional**. A single city proves the design; add another
region only for latency/availability demos. Prefer finishing Phase 4 failover
before expanding VPN.

---

## 4. Component design

### 4.1 Terraform (Layer 1)

New or extended module ideas (prefer extending `provisioners/gcp-compute` or a thin `vpn-gateways-gcp/`):

```hcl
# Pseudocode — not final module layout
variable "vpn_cities" {
  type = map(object({
    region       = string
    zone         = string
    machine_type = string  # e2-small minimum for WG + light k3s agent
    cidr         = string  # e.g. 10.50.0.0/24 for that city’s VPC subnet
  }))
}

resource "google_compute_instance" "vpn_gateway" {
  for_each     = var.vpn_cities
  name         = "hybrid-k8s-vpn-${each.key}"
  machine_type = each.value.machine_type
  zone         = each.value.zone
  tags         = ["hybrid-k8s-vpn", "vpn-gateway"]
  labels = {
    role = "vpn-gateway"
    city = each.key
  }
  # network interface + external IP (or reserve static for stable endpoints)
}

resource "google_compute_firewall" "wireguard" {
  name    = "hybrid-k8s-allow-wireguard"
  network = ...
  allow { protocol = "udp" ports = ["51820"] }
  source_ranges = var.vpn_client_cidrs  # lock to your home/ISP when possible
  target_tags   = ["vpn-gateway"]
}
```

**Inventory:** extend `generate-gcp-inventory.sh` **or** add `generate-vpn-inventory.sh` filtering `labels.role=vpn-gateway`.

**Standing recommendation:** VPN gateways in **separate VPCs or subnets** per city, peered or with clear SNAT. Don’t open WG to `0.0.0.0/0` forever in a portfolio demo — use `admin_cidr`-style ranges when you can.

### 4.2 Kubernetes / Helm (Layer 3)

Suggested chart path: `gitops/apps/wireguard-gateway/` (or `charts/wireguard-gateway`).

**Workload shape (v1):**

- `Deployment` (1 replica) **or** `DaemonSet` on nodes labeled `city=<name>`
- Privileged / `NET_ADMIN` + `/dev/net/tun` (document security trade-offs)
- ConfigMap: `wg0.conf` interface + peer public keys (server-side)
- Secret: server private key
- `hostNetwork: true` **or** NodePort/UDP LoadBalancer — prefer **hostNetwork on dedicated node** for simple UDP + stable public IP

**Server config sketch:**

```ini
[Interface]
Address = 10.66.<city_id>.1/24
ListenPort = 51820
PrivateKey = <from Secret>
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
# laptop
PublicKey = <client pubkey>
AllowedIPs = 10.66.<city_id>.2/32
```

Enable IP forwarding via Ansible `sysctl` on gateway nodes (`net.ipv4.ip_forward=1`).

### 4.3 Client config generation (multi-peer)

Scripts:

| Script | Purpose |
|--------|---------|
| `vpn-bootstrap.sh` | Server keys + first peer `laptop` + Ansible apply |
| `vpn-peer-add.sh` | New device keypair + IP + `.conf` |
| `vpn-peer-remove.sh` | Drop a peer |
| `vpn-peer-list.sh` | Show peers |
| `vpn-apply-peers.sh` | Push all peers to gateway |
| `generate-wg-client-config.sh` | Write stock client `.conf` |

Store private keys **only** under gitignored `vpn-clients/<city>/peers/`.

### 4.4 Traefik private routes (platform access demo)

Once VPN is up, add IngressRoute/Middleware that are **not** on the public LB — or protect with IPAllowList of WG client CIDRs. Demo:

- `https://argocd.internal/` only reachable when tunnel is up
- Grafana same pattern

This ties VPN → Traefik → existing stack (strong interview link).

### 4.5 Observability

Reuse kube-prometheus on **primary** (gateways are outside the cluster):

- Ansible installs `node_exporter` + WireGuard textfile metrics on the gateway VM
- Terraform firewall: `:9100` → `vpn_metrics_cidrs` / `admin_cidr`
- Scrape snippet: `./scripts/vpn-prometheus-scrape-snippet.sh`
- GitOps alerts/dashboard: `prometheus-rules-vpn.yaml`, `grafana-dashboard-vpn-configmap.yaml`
- Alerts: `WireGuardPeerHandshakeStale`, `VPNGatewayDown`, `WireGuardInterfaceDown`

See [CONSUMER-VPN.md](CONSUMER-VPN.md) §5 and [MONITORING.md](MONITORING.md#consumer-vpn-gateway).

### 4.6 HA semantics

| Failure | Desired behavior | Implementation |
|---------|------------------|----------------|
| Pod crash (same node) | Auto-heal | Deployment + hostNetwork restart |
| Node death (same city) | Second gateway in city **or** client fails over to another city profile | v1: document “switch profile”; v1.1: 2 nodes/city |
| Region outage | Use another city | Manual peer switch (good enough for portfolio) |
| Platform primary dies | VPN in region can still exit if gateway is independent | Prefer city gateways not depending on primary API for packet path |

**Important:** Control-plane HA (Phase 4 DNS) and **VPN exit HA** are separate. Don’t block VPN MVP on Cloud DNS.

---

## 5. Security

| Topic | Requirement |
|-------|-------------|
| Keys | Never commit private keys; rotate documented |
| Firewall | WG UDP only from known client CIDRs when demoing |
| Capabilities | Document `NET_ADMIN` / privileged; consider sidecar userspace WG later |
| NetworkPolicy | Deny-all in `vpn` ns except DNS + egress as needed |
| Audit | Log peer add/remove; keep peer inventory in git (pubkeys only) |
| Abuse | Personal use only; rate-limit isn’t required for MVP but mention it |

---

## 6. Build phases (runbooks)

### Phase V0 — Design locked (this doc)

- [x] Scope: multi-city WG on fantastic-spoon, stock clients
- [x] Confirm first city: `us-central1` (`city=us`)
- [x] Dedicated gateway VM (not k3s agent) for V1

### Phase V1 — Single city MVP (us-central1)

**Outcome:** One **consumer** WG exit; laptop reaches internet via full tunnel; metrics exporters on gateway.

1. [x] Terraform: `vpn-gateways-gcp/` — 1× `e2-small`, firewall UDP/51820  
2. [x] Ansible: `playbooks/vpn-gateway.yml` + `roles/wireguard-node` (NAT + exporters)  
3. [x] Host WireGuard (in-cluster Helm deferred — see `charts/wireguard-gateway/`)  
4. [x] Client config: `scripts/generate-wg-client-config.sh` + `vpn-bootstrap.sh` (full tunnel default)  
5. [ ] Verify: `curl ifconfig.me` shows GCE egress IP when full tunnel  
6. [x] `docs/VPN-RUNBOOK.md` + `docs/CONSUMER-VPN.md`  
7. [x] Prometheus scrape snippet + VPN alert rules / Grafana dashboard manifests

**Exit criteria:** Stable handshake; full-tunnel egress IP correct; keys not in git; exporters listening.

### Phase V1.1 — Multi-peer clients

**Outcome:** Multiple devices (laptop, phone, friend) on one city exit.

1. [x] `vpn-clients/<city>/peers/<name>.*` inventory  
2. [x] `scripts/vpn-peer-add.sh` / `remove` / `list` / `vpn-apply-peers.sh`  
3. [x] Ansible `wg_peers` loop in `wg0.conf.j2`  
4. [x] Docs in CONSUMER-VPN + VPN-RUNBOOK  

**Exit criteria:** Two devices online concurrently; `wg show` lists both peers.

### Phase V2 — Second city

1. Duplicate gateway in second region (HK / asia-east2)  
2. Second client profile  
3. Demo: switch city → different egress IP  
4. GitOps ApplicationSet or two Applications (`vpn-us`, `vpn-hk`)

**Exit criteria:** Two city configs; recorded loom/gif of IP change.

### Phase V3 — Platform private access + polish

1. Traefik InternalRoutes / IP allowlist for Argo + Grafana  
2. Prometheus alerts for peer freshness  
3. Optional: static IPs + Cloud DNS names `vpn-us.<domain>`, `vpn-hk.<domain>`  
4. Optional: second node per city for in-city HA

### Phase V4 — Stretch (only if energy left)

- Userspace WG to drop privileges  
- Tailscale subnet router **comparison** write-up (why WireGuard DIY taught more)  
- Automated fail-over script that rewrites client endpoint (still not a full app)

---

## 7. Repo layout (proposed)

```
vpn-gateways-gcp/                 # optional Terraform stack (or extend cloud-services-gcp)
gitops/apps/wireguard-gateway/    # Helm values per city
ansible/roles/wireguard-node/     # sysctl, packages, labeled nodes
scripts/generate-wg-client-config.sh
scripts/vpn-peers.md.example      # pubkey inventory
docs/VPN-ARCHITECTURE.md          # this file
docs/VPN-RUNBOOK.md               # operate / failover (add during V1)
vpn-clients/                      # gitignored local configs
```

Link from root `README.md` Documentation section when this ships.

---

## 8. Implementation checklist (V1 first PR)

1. Terraform gateway instance + firewall in `us-central1`  
2. Inventory generation for `role=vpn-gateway`  
3. Ansible: `net.ipv4.ip_forward`, WireGuard apt/package or chart-only  
4. Helm chart + Argo Application (manual `helm` apply acceptable for first PR)  
5. Client config script + `.gitignore` for `vpn-clients/`  
6. Runbook: connect, test egress IP, tear down  
7. Security note in PR description

Do **not** block on Phase 4 shared-services DNS. Do **not** start a client app.

---

## 9. Demo script (interview)

**Canonical walkthrough:** [PORTFOLIO-DEMO.md](PORTFOLIO-DEMO.md) (5–15 min; V1 = host WireGuard VM).

Summary: architecture → `./scripts/vpn.sh up` / `ip` → Grafana port-forward (not over the
consumer tunnel) → optional Phase 4 witness talk. Do **not** `kubectl get pods -n vpn`
(there is no vpn namespace in V1).

---

## 10. Cost & ops notes

- Prefer `e2-small` for gateways (same lesson as standby: `e2-micro` is too small when coupled with k3s agents).  
- Idle cost ≈ sum of gateway VMs + tiny egress. Stop/destroy gateways when not demoing (`./setup.sh destroy` patterns).  
- Static external IPs avoid client config churn.

---

## 11. Decision log (fill as you build)

| Date | Decision | Notes |
|------|----------|-------|
| 2026-07-14 | WireGuard + stock clients; multi-region exits | No custom app |
| 2026-07-14 | Additive to fantastic-spoon | Not a greenfield rewrite |
| 2026-07-14 | Dedicated VM (host WG), not k3s agent | Avoids inventory/ApplicationSet coupling |
| 2026-07-16 | Product = consumer full-tunnel VPN | Traefik stays for ops plane only |
| 2026-07-16 | Monitor via node_exporter + WG textfile → primary Prometheus | Additive; separate VPC |
| 2026-07-16 | Multi-peer client inventory + Ansible `wg_peers` | Consumer multi-device |
| TBD | First second city region | Suggest asia-east2 (`city=hk`) |
---

## Next action

V1 code landed under `vpn-gateways-gcp/` + `scripts/vpn-bootstrap.sh`.

1. Copy `vpn-gateways-gcp/terraform.tfvars.example` → `terraform.tfvars`  
2. `terraform -chdir=vpn-gateways-gcp apply`  
3. `./scripts/vpn-bootstrap.sh`  
4. Import `vpn-clients/us/laptop-us.conf` into WireGuard  

Then Phase V2 (second city) only after V1 is boringly reliable.
