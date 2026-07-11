# Libvirt / QEMU Provisioner

Simulates bare-metal provisioning locally using KVM VMs. Free — no AWS cost for primary compute.

## Project

`bare-metal-simulation/` — Terraform + libvirt provider

## Requirements

- Linux host with KVM (`qemu-kvm`)
- 16+ GB RAM recommended for 5 VMs

## Usage

```yaml
# config/clusters.yaml
primary:
  provisioner: libvirt
  terraform_dir: bare-metal-simulation
  inventory: ansible/inventory/libvirt-primary.yml
  profile: primary
```

```bash
./scripts/provision.sh primary
./scripts/bootstrap-cluster.sh primary
```

## Notes

- VMs use a NAT network (`192.168.122.0/24`) — SSH from host only unless port-forwarded
- After `terraform apply`, verify IPs: `virsh domifaddr hybrid-k8s-node-1`
- Same Ansible playbooks as EC2 and on-prem

## Path to real hardware

Libvirt inventory format is identical to on-prem. When you get physical servers, copy the same host layout to `on-prem.primary.yml` with real IPs — no Ansible changes needed.
