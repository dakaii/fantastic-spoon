# AWS EC2 Provisioner

Creates EC2 instances via Terraform. Treats cloud VMs as bare-metal equivalents — you own the OS, install k3s yourself.

## Projects

| Cluster | Terraform dir | Instance types (dev) |
|---------|---------------|----------------------|
| Primary | `primary-cluster/` | 1× t4g.small CP + 2× t4g.small workers |
| Standby | `cloud-services/` | 1× t4g.micro CP + 1× t4g.micro agent + S3 |

## Usage

```bash
./scripts/provision.sh primary    # aws-ec2 when configured in clusters.yaml
./scripts/bootstrap-cluster.sh primary
```

Or use phase scripts directly:

```bash
./scripts/phase1-primary.sh
./scripts/phase2-standby.sh
```

## Outputs

Each project writes:

- `ansible/inventory/<cluster>-hosts.yml` — standard inventory
- `ansible/inventory/<cluster>-meta.json` — ingress DNS, API host, provisioner tag

## Replacing with on-prem

When ready to move primary to physical hardware:

1. Bootstrap on-prem using [on-prem provisioner](../on-prem/)
2. Update `config/clusters.yaml`
3. `terraform destroy` in `primary-cluster/`

Standby can remain on EC2 for hybrid DR.
