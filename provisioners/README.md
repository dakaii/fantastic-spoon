# Provisioners

Layer 1 of the platform. Each provisioner creates nodes and outputs a standard Ansible inventory.

| Provisioner | Directory | Best for |
|-------------|-----------|----------|
| [gcp-compute](gcp-compute/) | `primary-cluster-gcp/`, `cloud-services-gcp/` | **Default** — all-cloud on GCP, multi-project accounts |
| [aws-ec2](aws-ec2/) | `primary-cluster/`, `cloud-services/` | All-cloud on AWS |
| [libvirt](libvirt/) | `bare-metal-simulation/` | Free local dev, simulates on-prem |
| [on-prem](on-prem/) | Manual inventory | Raspberry Pi, Mac Mini, rack servers |

**Switch provisioners** in `config/clusters.yaml` — Ansible and GitOps stay the same.

See [docs/PORTABLE-ARCHITECTURE.md](../docs/PORTABLE-ARCHITECTURE.md).
