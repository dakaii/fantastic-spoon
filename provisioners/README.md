# Provisioners

Layer 1 of the platform. Each provisioner creates nodes and outputs a standard Ansible inventory.

| Provisioner | Directory | Best for |
|-------------|-----------|----------|
| [aws-ec2](aws-ec2/) | `primary-cluster/`, `cloud-services/` | All-cloud, learning AWS |
| [libvirt](libvirt/) | `bare-metal-simulation/` | Free local dev, simulates on-prem |
| [on-prem](on-prem/) | Manual inventory | Raspberry Pi, Mac Mini, rack servers |

**Switch provisioners** in `config/clusters.yaml` — Ansible and GitOps stay the same.

See [docs/PORTABLE-ARCHITECTURE.md](../docs/PORTABLE-ARCHITECTURE.md).
