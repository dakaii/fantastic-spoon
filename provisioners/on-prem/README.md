# On-Prem Provisioner

Use real physical servers instead of EC2 or libvirt VMs. No Terraform required for the nodes themselves.

## Supported hardware

- Raspberry Pi 4/5 (ARM64, Ubuntu 24.04)
- Mac Mini (x86 or ARM, Ubuntu or Debian)
- Any x86/ARM server with Ubuntu 22.04+ or Debian 12+

## Requirements per node

| Role | Min RAM | Min CPU | Min disk |
|------|---------|---------|----------|
| Control plane | 2 GB | 2 cores | 20 GB |
| Worker | 2 GB | 2 cores | 20 GB |

## Setup steps

### 1. Install OS

Flash Ubuntu Server 24.04 (64-bit) on each machine. Enable SSH.

### 2. Prepare each node

On each server:

```bash
scp provisioners/on-prem/prepare-node.sh ubuntu@192.168.1.10:/tmp/
ssh ubuntu@192.168.1.10 'sudo bash /tmp/prepare-node.sh onprem-cp-1 server'
```

Repeat for each worker with `agent` role.

### 3. Create inventory

```bash
cp provisioners/on-prem/inventory.primary.example.yml \
   ansible/inventory/on-prem.primary.yml
# Edit IPs and hostnames
```

### 4. Update cluster config

```yaml
# config/clusters.yaml
primary:
  provisioner: on-prem
  inventory: ansible/inventory/on-prem.primary.yml
  profile: primary
```

### 5. Bootstrap

```bash
cp config/clusters.example.yaml config/clusters.yaml  # if not done
./scripts/bootstrap-cluster.sh primary
```

## Hybrid: on-prem primary + AWS standby

Keep standby on EC2 for cloud DR. Only change the primary block in `config/clusters.yaml`:

```yaml
primary:
  provisioner: on-prem
  inventory: ansible/inventory/on-prem.primary.yml
  profile: primary

standby:
  provisioner: aws-ec2
  terraform_dir: cloud-services
  inventory: ansible/inventory/standby-hosts.yml
  profile: standby
```

Failover (Layer 4) still uses AWS Route53 + Lambda to detect on-prem failure and switch to EC2 standby.

## Replacing EC2 with on-prem later

1. Bootstrap on-prem cluster with steps above
2. Sync GitOps apps to new cluster (same Argo CD manifests)
3. Update Route53 health check target to on-prem `ingress_host`
4. `terraform destroy` in `primary-cluster/`

See [docs/PORTABLE-ARCHITECTURE.md](../../docs/PORTABLE-ARCHITECTURE.md) for the full migration checklist.
