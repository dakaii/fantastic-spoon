#!/usr/bin/env bash
# provision.sh — Layer 1: Create nodes via configured provisioner
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${REPO_ROOT}/config/clusters.yaml"
CLUSTER="${1:?Usage: provision.sh <primary|standby>}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Create config/clusters.yaml from config/clusters.example.yaml"
  exit 1
fi

get_config() {
  local cluster="$1" key="$2"
  awk -v cluster="$cluster" -v key="$key" '
    $0 ~ "^" cluster ":" { found=1; next }
    found && $0 ~ /^[a-z]/ && $0 !~ /^  / { found=0 }
    found && $0 ~ "^  " key ":" {
      sub(/^  [^:]+: */, "")
      gsub(/"/, "")
      print
      exit
    }
  ' "$CONFIG"
}

PROVISIONER=$(get_config "$CLUSTER" provisioner)
TF_DIR=$(get_config "$CLUSTER" terraform_dir)
INVENTORY_REL=$(get_config "$CLUSTER" inventory)

echo "==> Provision cluster: ${CLUSTER} (provider: ${PROVISIONER})"

case "$PROVISIONER" in
  gcp-compute)
    if [[ -z "$TF_DIR" ]]; then
      echo "ERROR: terraform_dir required for gcp-compute provisioner"
      exit 1
    fi
    TF_PATH="${REPO_ROOT}/${TF_DIR}"
    if [[ ! -f "${TF_PATH}/terraform.tfvars" ]]; then
      echo "Create ${TF_PATH}/terraform.tfvars from terraform.tfvars.example"
      exit 1
    fi
    cd "$TF_PATH"
    terraform init
    terraform apply -auto-approve
    terraform output -raw ansible_inventory > "${REPO_ROOT}/${INVENTORY_REL}"
    if terraform output -json cluster_meta &>/dev/null; then
      terraform output -json cluster_meta > "${REPO_ROOT}/${INVENTORY_REL%.yml}.meta.json"
    fi
    echo "Inventory written: ${INVENTORY_REL}"
    ;;

  aws-ec2)
    if [[ -z "$TF_DIR" ]]; then
      echo "ERROR: terraform_dir required for aws-ec2 provisioner"
      exit 1
    fi
    TF_PATH="${REPO_ROOT}/${TF_DIR}"
    if [[ ! -f "${TF_PATH}/terraform.tfvars" ]]; then
      echo "Create ${TF_PATH}/terraform.tfvars from terraform.tfvars.example"
      exit 1
    fi
    cd "$TF_PATH"
    terraform init
    terraform apply -auto-approve
    terraform output -raw ansible_inventory > "${REPO_ROOT}/${INVENTORY_REL}"
    if terraform output -json cluster_meta &>/dev/null; then
      terraform output -json cluster_meta > "${REPO_ROOT}/${INVENTORY_REL%.yml}.meta.json"
    fi
    echo "Inventory written: ${INVENTORY_REL}"
    ;;

  libvirt)
    if [[ -z "$TF_DIR" ]]; then
      TF_DIR="bare-metal-simulation"
    fi
    TF_PATH="${REPO_ROOT}/${TF_DIR}"
    cd "$TF_PATH"
    if [[ ! -f terraform.tfvars ]] && [[ -z "${TF_VAR_ssh_public_key:-}" ]]; then
      echo "Run: terraform apply -var=\"ssh_public_key=\$(cat ~/.ssh/id_ed25519.pub)\""
      exit 1
    fi
    terraform init
    terraform apply -auto-approve
    terraform output -raw ansible_inventory > "${REPO_ROOT}/${INVENTORY_REL}"
    if terraform output -json cluster_meta &>/dev/null; then
      terraform output -json cluster_meta > "${REPO_ROOT}/${INVENTORY_REL%.yml}.meta.json"
    fi
    echo "Inventory written: ${INVENTORY_REL}"
    echo "Verify VM IPs: virsh domifaddr <node-name>"
    ;;

  on-prem)
    echo "On-prem provisioner: no Terraform step."
    echo "1. Run provisioners/on-prem/prepare-node.sh on each server"
    echo "2. Ensure inventory exists: ${INVENTORY_REL}"
    if [[ ! -f "${REPO_ROOT}/${INVENTORY_REL}" ]]; then
      echo ""
      echo "Create inventory from example:"
      echo "  cp provisioners/on-prem/inventory.${CLUSTER}.example.yml ${INVENTORY_REL}"
      exit 1
    fi
    "${REPO_ROOT}/scripts/validate-inventory.sh" "${REPO_ROOT}/${INVENTORY_REL}"
    echo "Inventory ready: ${INVENTORY_REL}"
    ;;

  *)
    echo "ERROR: Unknown provisioner '${PROVISIONER}'"
    echo "Supported: gcp-compute, aws-ec2, libvirt, on-prem"
    exit 1
    ;;
esac

echo "Next: ./scripts/bootstrap-cluster.sh ${CLUSTER}"
