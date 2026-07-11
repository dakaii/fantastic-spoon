#!/usr/bin/env bash
# phase2-standby.sh — Provision standby cluster, S3 backups, and bootstrap k3s
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STANDBY_DIR="${REPO_ROOT}/cloud-services"
ANSIBLE_DIR="${REPO_ROOT}/ansible"
INVENTORY="${ANSIBLE_DIR}/inventory/standby-hosts.yml"

cd "$STANDBY_DIR"

if [[ ! -f terraform.tfvars ]]; then
  echo "Create cloud-services/terraform.tfvars from terraform.tfvars.example first."
  exit 1
fi

echo "==> Terraform init"
terraform init

echo "==> Terraform apply (standby cluster + S3)"
terraform apply

echo "==> Writing Ansible inventory"
terraform output -raw ansible_inventory > "$INVENTORY"

VELERO_BUCKET=$(terraform output -raw backup_bucket_name)
VELERO_KEY=$(terraform output -raw velero_access_key_id)
VELERO_SECRET=$(terraform output -raw velero_secret_access_key)

echo "==> Waiting for nodes to accept SSH"
bash "${REPO_ROOT}/scripts/wait-for-nodes.sh" "$INVENTORY"

echo "==> Bootstrapping k3s (standby) + Argo CD"
cd "$ANSIBLE_DIR"
ansible-playbook -i inventory/standby-hosts.yml playbooks/site.yml \
  -e cluster_profile=standby \
  -e cluster_name=standby \
  -e "velero_bucket=${VELERO_BUCKET}" \
  -e "velero_access_key=${VELERO_KEY}" \
  -e "velero_secret_key=${VELERO_SECRET}"

echo ""
echo "==> Phase 2 complete"
echo "Standby NLB: $(terraform -chdir="$STANDBY_DIR" output -raw standby_nlb_dns_name)"
echo "Velero bucket: ${VELERO_BUCKET}"
echo ""
echo "Next: register standby cluster in primary Argo CD (gitops/argocd/clusters/cloud-standby.yaml)"
echo "Then: scripts/phase3-gitops.sh (when ready)"
