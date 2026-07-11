#!/usr/bin/env bash
# phase1-primary.sh — Provision and bootstrap the primary k3s cluster
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRIMARY_DIR="${REPO_ROOT}/primary-cluster"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/primary-hosts.yml"

cd "$PRIMARY_DIR"

if [[ ! -f terraform.tfvars ]]; then
  echo "Create primary-cluster/terraform.tfvars from terraform.tfvars.example first."
  exit 1
fi

echo "==> Terraform init"
terraform init

echo "==> Terraform apply (primary cluster)"
terraform apply

echo "==> Writing Ansible inventory"
terraform output -raw ansible_inventory > "$INVENTORY"

echo "==> Waiting for nodes to accept SSH"
bash "${REPO_ROOT}/scripts/wait-for-nodes.sh" "$INVENTORY"

echo "==> Installing Ansible collections"
ansible-galaxy collection install -r "${ANSIBLE_DIR}/requirements.yml"

echo "==> Bootstrapping k3s (primary)"
cd "$ANSIBLE_DIR"
ansible-playbook -i inventory/primary-hosts.yml playbooks/site.yml \
  -e cluster_profile=primary \
  -e cluster_name=primary

echo ""
echo "==> Phase 1 complete"
echo "Primary NLB: $(terraform -chdir="$PRIMARY_DIR" output -raw primary_nlb_dns_name)"
echo ""
echo "Fetch kubeconfig:"
FIRST_CP=$(grep -A1 'k3s_server:' "$INVENTORY" | grep ansible_host | head -1 | awk '{print $2}')
echo "  ssh ubuntu@${FIRST_CP} sudo cat /etc/rancher/k3s/k3s.yaml"
echo ""
echo "Next: run scripts/phase2-standby.sh"
