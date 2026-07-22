# Portfolio Demo (5–15 min)

Interview / portfolio walkthrough for this repo. **Do not run full `./setup.sh` live**
(20–40 min). Bring the stack up the night before; demo is show + talk.

Product one-liner:

> Portable k3s primary/standby with Cloud Function witness, plus an additive
> WireGuard **consumer VPN** monitored by the same Prometheus/Grafana stack.

Deep dives: [CONSUMER-VPN.md](CONSUMER-VPN.md) · [VPN-RUNBOOK.md](VPN-RUNBOOK.md) ·
[PHASE-4-RUNBOOK.md](PHASE-4-RUNBOOK.md) · [MONITORING.md](MONITORING.md)

---

## Night before (not during the call)

| Ready | How |
|-------|-----|
| Primary (+ optional standby) | `./setup.sh` or GHA **GCP Deploy All** / Bootstrap — [GCP-DEPLOY.md](GCP-DEPLOY.md) |
| VPN city (`us`) | GHA **GCP VPN** or `./scripts/vpn-bootstrap.sh` — client conf under `vpn-clients/us/` |
| Monitoring wired | VPN deploy runs `vpn-monitoring-wire.sh`; confirm scrape if primary was already up |
| Auth | Same Google account for `gcloud` **and** ADC (`gcloud auth application-default login`). Use `GCP_ACCOUNT=you@gmail.com` locally — **no email in git** |
| Grafana password | See [MONITORING.md](MONITORING.md) (rotate off the Ansible default before demos) |
| Optional Phase 4 | Witness (+ DNS if you have a domain) — [PHASE-4-RUNBOOK.md](PHASE-4-RUNBOOK.md) |

Smoke check:

```bash
kubectl get nodes
./scripts/vpn.sh status          # or confirm vpn-clients/us/laptop-us.conf exists
terraform -chdir=vpn-gateways-gcp output -raw vpn_public_ip
```

---

## Path A — 5 minutes (must-show)

### 1. Architecture (30s)

README layers or [GCP-ARCHITECTURE.md](GCP-ARCHITECTURE.md):

```
Layer 4  shared-services-gcp/   DNS + witness
Layer 3  gitops/                Argo CD apps
Layer 2  ansible/               k3s bootstrap (provider-agnostic)
Layer 1  provisioners/          gcp-compute | on-prem | …  ← swap here
         + vpn-gateways-gcp/    consumer VPN (additive VPC)
```

Say: **portable control plane** + **consumer egress** beside it — Traefik is ops/apps,
not the browse path.

### 2. Consumer VPN egress (2 min)

```bash
./scripts/vpn.sh up us laptop
./scripts/vpn.sh ip
# or: curl -4 ifconfig.me
terraform -chdir=vpn-gateways-gcp output -raw vpn_public_ip
```

**On screen:** public IP matches the gateway. One sentence: full-tunnel WireGuard on a
**dedicated GCE VM** (host `wg0`), not a Deployment in the cluster.

```bash
./scripts/vpn.sh down us laptop
```

### 3. Monitoring (2 min)

```bash
kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80
# http://localhost:3000  user admin — password in MONITORING.md (change before demos)
```

Open **Hybrid K8s Platform Overview** and **Consumer VPN Gateway**. Point out:

- Grafana is reached via **kubectl port-forward**, not the consumer tunnel
- Prometheus scrapes gateway `:9100` from primary NAT IPs (`vpn_metrics_cidrs`)

### 4. Close the loop (30s)

Point at `vpn-gateways-gcp/` + `ansible/roles/wireguard-node` + GitOps monitoring rules.
Mention primary/standby + Velero if asked about DR without running failover.

---

## Path B — 10–15 minutes (add failover story)

Do Path A, then:

### 5. Witness / DNS (talk + light show)

```bash
./scripts/failover-gcp.sh status
# Witness logs (if deployed):
gcloud functions logs read hybrid-k8s-witness --gen2 --region=us-central1 --limit=10
```

Talk: Cloud Function probes primary `/readyz`; Cloud DNS can flip A records to standby
LB. **Level C app activation is still manual** (`activate-apps`) — say that honestly.

### 6. Optional live Level C (only if standby is warm)

```bash
# After copying standby kubeconfig:
STANDBY_KUBECONFIG=~/.kube/hybrid-standby.yaml ./scripts/failover-gcp.sh activate-apps
```

Do **not** simulate a real outage mid-interview unless you’ve rehearsed DNS cutover.

### 7. Portability soundbite

`config/clusters.yaml` → change `provisioner`; Ansible + GitOps stay. That’s the
“not locked to GCE” pitch — [PORTABLE-ARCHITECTURE.md](PORTABLE-ARCHITECTURE.md).

---

## Do not demo live

| Skip | Why |
|------|-----|
| Full `./setup.sh` / Terraform apply | Too slow; flaky mid-call |
| Creating a GCP project / fixing `admin_cidr` | Ops rabbit hole |
| `kubectl get pods -n vpn` | V1 has **no** vpn namespace — host WireGuard VM |
| “Grafana only works over the VPN” | False — port-forward; consumer tunnel is egress |
| Claiming fully automated app failover | Phase 4 Level C is operator-assisted |

---

## Talk-track traps (correct answers)

| Question | Answer |
|----------|--------|
| Why Ansible and Terraform? | TF = VMs/network; Ansible = bootstrap only (not day-2). Apps = Argo. |
| Why not Talos? | Next upgrade for immutable nodes; current path ships the portfolio story faster. |
| Is VPN in the cluster? | No — dedicated VM, separate VPC; metrics scraped into cluster Prometheus. |
| How do you stop the bill? | Tear down when idle (below). |

---

## Teardown (after the call / when idle)

```bash
# VPN only (clusters untouched)
./scripts/vpn.sh destroy          # prints GHA command
# or: GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-vpn-destroy-ci.sh

# Full stop-billing teardown
GCP_PROJECT=hybrid-k8s-dev ./setup.sh destroy
# or: GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-teardown.sh --gha --watch
```

Prefer a GitHub Environment with required reviewers on **GCP Destroy** —
[GITHUB-ACTIONS-SETUP.md](GITHUB-ACTIONS-SETUP.md).

---

## Resume bullets (copy-paste)

- Designed a portable hybrid k3s platform (Terraform provisioners + Ansible bootstrap + Argo CD) with warm standby and Velero backups on GCP.
- Built an additive multi-city WireGuard consumer VPN (full-tunnel egress, stock clients) with Prometheus/Grafana peer and host health.
- Implemented Cloud Function witness + Cloud DNS failover path; documented operator Level C app activation on standby.
