# Phase 1 Runbook — Primary k3s Cluster on AWS

Deploy the primary EC2-based k3s cluster. Complete this before Phase 2 (standby).

## Prerequisites

Install these on your **local machine** (the Terraform/Ansible control node):

| Tool | Version | Install |
|------|---------|---------|
| Terraform | ≥ 1.5 | https://developer.hashicorp.com/terraform/install |
| AWS CLI | v2 | `aws configure` with access key or SSO |
| Ansible | ≥ 2.15 | `pip install ansible` |
| SSH key | ed25519 | `ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519` |

Verify AWS access:

```bash
aws sts get-caller-identity
```

## Step 1 — Configure variables

```bash
cd primary-cluster
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
ssh_public_key = "ssh-ed25519 AAAA... your-key"
admin_cidr     = "YOUR.IP.ADDRESS/32"   # curl -s ifconfig.me
```

## Step 2 — Deploy (automated script)

```bash
chmod +x scripts/phase1-primary.sh scripts/wait-for-nodes.sh
./scripts/phase1-primary.sh
```

Or manually:

```bash
cd primary-cluster
terraform init
terraform apply
terraform output -raw ansible_inventory > ../ansible/inventory/primary-hosts.yml

# Wait ~2 min for cloud-init, then:
../scripts/wait-for-nodes.sh ../ansible/inventory/primary-hosts.yml

cd ../ansible
ansible-galaxy collection install -r requirements.yml
ansible-playbook -i inventory/primary-hosts.yml playbooks/site.yml \
  -e cluster_profile=primary -e cluster_name=primary
```

## Step 3 — Verify cluster

```bash
# Get first control plane IP from inventory
CP_IP=$(grep ansible_host ansible/inventory/primary-hosts.yml | head -1 | awk '{print $2}')

# Copy kubeconfig locally
ssh ubuntu@$CP_IP "sudo cat /etc/rancher/k3s/k3s.yaml" > ~/.kube/hybrid-primary.yaml
sed -i "s/127.0.0.1/${CP_IP}/" ~/.kube/hybrid-primary.yaml
export KUBECONFIG=~/.kube/hybrid-primary.yaml

kubectl get nodes
kubectl get pods -A
```

Expected output: 3 nodes `Ready` (1 control plane + 2 workers in dev profile).

## Step 4 — Verify ingress NLB

```bash
cd primary-cluster
terraform output primary_nlb_dns_name
# curl -k https://<nlb-dns-name>  (after Traefik is up)
```

## What gets installed

| Component | Namespace |
|-----------|-----------|
| k3s | system |
| Cilium CNI | kube-system |
| Longhorn storage | longhorn-system |
| Traefik ingress | traefik |
| Argo CD | argocd |
| Prometheus + Grafana | monitoring |
| Velero | velero (needs bucket from Phase 2) |

## Troubleshooting

**SSH connection refused**
- Wait 2–3 minutes for cloud-init to finish
- Check security group allows your IP in `admin_cidr`
- Verify instance is running: `aws ec2 describe-instances --filters "Name=tag:Cluster,Values=primary"`

**Ansible k3s install fails**
- SSH to node manually: `ssh ubuntu@<ip>`
- Check cloud-init log: `sudo cat /var/log/cloud-init-output.log`

**Cilium helm fails**
- Ensure k3s is running: `sudo k3s kubectl get nodes`
- Cilium needs kernel modules — cloud-init loads them

## Cost while running

Dev profile (1 CP + 2 workers, t4g.small): **~$36/month**

Remember to destroy when not in use:

```bash
cd primary-cluster && terraform destroy
```

## Next

→ [Phase 2 Runbook](PHASE-2-RUNBOOK.md) — standby cluster + S3 backups
