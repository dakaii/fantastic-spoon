# Hybrid Bare-Metal Kubernetes Platform

Portable k3s platform — swap GCE for on-prem hardware without rewriting Ansible or GitOps.

## Architecture

```
Layer 4  shared-services-gcp/  Cloud DNS, Cloud Function witness (GCP)
Layer 3  gitops/                Argo CD, apps
Layer 2  ansible/               k3s bootstrap (same for all providers)
Layer 1  provisioners/          gcp-compute | aws-ec2 | libvirt | on-prem  ← swap here
```

**Switch primary from GCE to Raspberry Pi:** change one line in `config/clusters.yaml`, run bootstrap again. See [docs/PORTABLE-ARCHITECTURE.md](docs/PORTABLE-ARCHITECTURE.md).

## Quick Start (GCP — default)

```bash
gcloud auth application-default login   # once per machine
./setup.sh                            # everything else
```

Tear down when idle: `./setup.sh destroy`

Optional: `GCP_PROJECT=hybrid-k8s-dev ./setup.sh`

Details: [docs/GCP-DEPLOY.md](docs/GCP-DEPLOY.md)

## Quick Start (On-Prem Primary)

```bash
# config/clusters.yaml
primary:
  provisioner: on-prem
  inventory: ansible/inventory/on-prem.primary.yml
  profile: primary

cp provisioners/on-prem/inventory.primary.example.yml ansible/inventory/on-prem.primary.yml
# edit IPs, run prepare-node.sh on each server

./scripts/bootstrap-cluster.sh primary
```

## Quick Start (AWS — alternative)

```bash
# config/clusters.yaml — set provisioner: aws-ec2, terraform_dir: primary-cluster / cloud-services
cp primary-cluster/terraform.tfvars.example primary-cluster/terraform.tfvars
./scripts/phase1-primary.sh
```

## Project Structure

```
config/clusters.yaml              ← switch provisioner per cluster
provisioners/                     ← gcp-compute, aws-ec2, libvirt, on-prem
primary-cluster-gcp/              ← GCP primary Terraform (default)
cloud-services-gcp/               ← GCP standby + GCS
shared-services-gcp/              ← GCP failover layer
vpn-gateways-gcp/                 ← Consumer VPN city exits (WireGuard; additive)
primary-cluster/                  ← AWS alternative
cloud-services/                   ← AWS alternative
bare-metal-simulation/            ← libvirt local VMs
ansible/                          ← provider-agnostic bootstrap (+ vpn-gateway playbook)
gitops/                           ← provider-agnostic apps
shared-services/                  ← AWS failover layer
scripts/provision.sh              ← Layer 1 entry point
scripts/bootstrap-cluster.sh      ← Layer 2 entry point
scripts/vpn-bootstrap.sh          ← WireGuard city bootstrap (additive)
scripts/vpn.sh                    ← CLI connect/disconnect (up/down/ip)
scripts/gcp-teardown.sh           ← stop-billing teardown (local or --gha)
```

## Documentation

- [GCP Architecture (default)](docs/GCP-ARCHITECTURE.md)
- [GCP Deploy guide — local scripts vs GitHub Actions](docs/GCP-DEPLOY.md)
- [GitHub Actions setup — secrets, workflows, VPN/monitoring post-steps](docs/GITHUB-ACTIONS-SETUP.md)
- [Monitoring — Prometheus alerts + Grafana](docs/MONITORING.md)
- [Portable architecture — swap cloud for on-prem](docs/PORTABLE-ARCHITECTURE.md)
- [Phase 1 Runbook — Primary cluster](docs/PHASE-1-RUNBOOK.md)
- [Phase 2 Runbook — Standby + backups](docs/PHASE-2-RUNBOOK.md)
- [Phase 4 Runbook — Witness + Cloud DNS failover](docs/PHASE-4-RUNBOOK.md)
- [GCP Bootstrap Issues — errors & fixes log](docs/GCP-BOOTSTRAP-ISSUES.md)
- [Consumer VPN — product overview (full-tunnel + Traefik split)](docs/CONSUMER-VPN.md)
- [VPN Architecture — multi-region WireGuard gateways](docs/VPN-ARCHITECTURE.md)
- [VPN Runbook — deploy / verify / destroy a city](docs/VPN-RUNBOOK.md)
- [AWS Architecture (alternative)](docs/AWS-ARCHITECTURE.md)
- [GCP Compute provisioner](provisioners/gcp-compute/README.md)
- [On-prem provisioner](provisioners/on-prem/README.md)
