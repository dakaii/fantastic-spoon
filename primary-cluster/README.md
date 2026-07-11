# Primary Cluster — EC2 "Bare-Metal" Emulation

Provisions EC2 instances that act as bare-metal Kubernetes nodes for the primary k3s cluster. No QEMU or nested virtualization — EC2 instances are provisioned directly via Terraform and bootstrapped with cloud-init + Ansible.

## What Gets Created

| Resource | Purpose |
|----------|---------|
| VPC + subnets (multi-AZ) | Network isolation |
| EC2 instances | k3s control plane + worker nodes |
| NLB | Ingress endpoint for Route53 failover |
| Security group | SSH, k3s API, HTTP/S, NodePort |

## Usage

```bash
terraform init
terraform plan \
  -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var="admin_cidr=$(curl -s ifconfig.me)/32"
terraform apply \
  -var="ssh_public_key=$(cat ~/.ssh/id_ed25519.pub)" \
  -var="admin_cidr=$(curl -s ifconfig.me)/32"
```

Save the `ansible_inventory` output, then bootstrap k3s:

```bash
terraform output -raw ansible_inventory > ../ansible/inventory/primary-hosts.yml
cd ../ansible
ansible-playbook -i inventory/primary-hosts.yml playbooks/site.yml
```

## Sizing

| Profile | Control plane | Workers | ~$/month |
|---------|--------------|---------|----------|
| Dev (default) | 1× t4g.small | 2× t4g.small | ~$36 |
| HA | 3× t4g.small | 2× t4g.small | ~$60 |

See [docs/AWS-ARCHITECTURE.md](../docs/AWS-ARCHITECTURE.md) for the full design.
