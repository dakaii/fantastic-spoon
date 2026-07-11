# Bare-Metal Simulation (Terraform + libvirt)

Provisions QEMU/KVM virtual machines that simulate bare-metal Kubernetes nodes.

## Prerequisites

```bash
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients \
  cloud-image-utils genisoimage
sudo usermod -aG libvirt $USER
```

## Usage

```bash
terraform init
terraform plan -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"
terraform apply -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)"
```

After apply, copy the `ansible_inventory` output into `../ansible/inventory/hosts.yml`, resolve node IPs (via `virsh domifaddr`), then run Ansible.

## Outputs

| Output | Description |
|--------|-------------|
| `node_names` | VM names in libvirt |
| `node_roles` | server vs agent assignment |
| `ansible_inventory` | Ready-to-use Ansible inventory YAML |

See [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) for the full platform design.
