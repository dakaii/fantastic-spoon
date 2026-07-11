#!/usr/bin/env bash
# bootstrap-cluster.sh — Layer 2: Bootstrap k3s on any provisioner
# Works identically for aws-ec2, libvirt, and on-prem inventories.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${REPO_ROOT}/config/clusters.yaml"
CLUSTER="${1:?Usage: bootstrap-cluster.sh <primary|standby>}"

if [[ ! -f "$CONFIG" ]]; then
  echo "Create config/clusters.yaml from config/clusters.example.yaml"
  exit 1
fi

# Parse YAML without yq dependency — simple grep-based extraction
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

INVENTORY_REL=$(get_config "$CLUSTER" inventory)
PROFILE=$(get_config "$CLUSTER" profile)
PROVISIONER=$(get_config "$CLUSTER" provisioner)

if [[ -z "$INVENTORY_REL" ]]; then
  echo "ERROR: No inventory defined for cluster '$CLUSTER' in $CONFIG"
  exit 1
fi

INVENTORY="${REPO_ROOT}/${INVENTORY_REL}"

echo "==> Bootstrap cluster: ${CLUSTER}"
echo "    Provisioner: ${PROVISIONER:-unknown}"
echo "    Profile:     ${PROFILE}"
echo "    Inventory:   ${INVENTORY}"

"${REPO_ROOT}/scripts/validate-inventory.sh" "$INVENTORY"

echo "==> Waiting for SSH"
"${REPO_ROOT}/scripts/wait-for-nodes.sh" "$INVENTORY"

echo "==> Installing Ansible collections"
ansible-galaxy collection install -r "${REPO_ROOT}/ansible/requirements.yml"

EXTRA_VARS=(
  -e "cluster_profile=${PROFILE}"
  -e "cluster_name=${CLUSTER}"
  -e "provisioner=${PROVISIONER}"
)

# Pass Velero creds for standby if meta file exists
META_FILE="${INVENTORY%.yml}.meta.json"
if [[ -f "$META_FILE" ]]; then
  echo "==> Loading cluster meta from ${META_FILE}"
  if command -v jq &>/dev/null; then
    BUCKET=$(jq -r '.velero_bucket // empty' "$META_FILE")
    KEY=$(jq -r '.velero_access_key // empty' "$META_FILE")
    SECRET=$(jq -r '.velero_secret_key // empty' "$META_FILE")
    [[ -n "$BUCKET" ]] && EXTRA_VARS+=(-e "velero_bucket=${BUCKET}")
    [[ -n "$KEY" ]] && EXTRA_VARS+=(-e "velero_access_key=${KEY}")
    [[ -n "$SECRET" ]] && EXTRA_VARS+=(-e "velero_secret_key=${SECRET}")
  fi
fi

echo "==> Running Ansible"
ansible-playbook \
  -i "$INVENTORY" \
  "${REPO_ROOT}/ansible/playbooks/site.yml" \
  "${EXTRA_VARS[@]}"

echo ""
echo "==> Bootstrap complete: ${CLUSTER}"
FIRST_CP=$(grep -A20 'k3s_server:' "$INVENTORY" | grep ansible_host | head -1 | awk '{print $2}')
echo "Verify: ssh ubuntu@${FIRST_CP} sudo k3s kubectl get nodes"
