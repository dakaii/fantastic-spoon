#!/usr/bin/env bash
# generate-gcp-inventory.sh — Build Ansible inventory from live GCE VMs (no local tfstate)
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/generate-gcp-inventory.sh primary
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/generate-gcp-inventory.sh standby
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLUSTER="${1:?Usage: generate-gcp-inventory.sh <primary|standby>}"

GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"
GCP_REGION="${GCP_REGION:-us-central1}"
PROJECT_NAME="${PROJECT_NAME:-hybrid-k8s}"
K3S_VERSION="${K3S_VERSION:-v1.29.5+k3s1}"

case "$CLUSTER" in
  primary|standby) ;;
  *)
    echo "ERROR: Unknown cluster '${CLUSTER}' (expected primary or standby)" >&2
    exit 1
    ;;
esac

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found" >&2
    exit 1
  }
}

require_cmd gcloud
require_cmd jq

INVENTORY_REL="ansible/inventory/${CLUSTER}-hosts.yml"
OUTPUT="${2:-${REPO_ROOT}/${INVENTORY_REL}}"
mkdir -p "$(dirname "$OUTPUT")"

instances_json="$(gcloud compute instances list \
  --project="$GCP_PROJECT" \
  --filter="labels.cluster=${CLUSTER}" \
  --format=json)"

instance_count="$(echo "$instances_json" | jq 'length')"
if [[ "$instance_count" -eq 0 ]]; then
  echo "ERROR: No GCE instances found with labels.cluster=${CLUSTER} in project ${GCP_PROJECT}" >&2
  exit 1
fi

lb_name="${PROJECT_NAME}-${CLUSTER}-https"
ingress_host="$(gcloud compute forwarding-rules describe "$lb_name" \
  --project="$GCP_PROJECT" \
  --region="$GCP_REGION" \
  --format='value(IPAddress)' 2>/dev/null || true)"

if [[ -z "$ingress_host" ]]; then
  echo "WARN: Could not read forwarding rule ${lb_name}; ingress_host will be empty" >&2
fi

k3s_api_host="$(echo "$instances_json" | jq -r '
  [.[] | select(.labels.role == "server") | .networkInterfaces[0].accessConfigs[0].natIP][0] // empty
')"

k3s_api_internal="$(echo "$instances_json" | jq -r '
  [.[] | select(.labels.role == "server") | .networkInterfaces[0].networkIP][0] // empty
')"

if [[ -z "$k3s_api_host" ]]; then
  echo "ERROR: No control plane (labels.role=server) found for cluster ${CLUSTER}" >&2
  exit 1
fi

write_host_group() {
  local group_name="$1"
  local role="$2"

  echo "    ${group_name}:"
  echo "      hosts:"

  local hosts
  hosts="$(echo "$instances_json" | jq -r --arg role "$role" '
    .[] | select(.labels.role == $role) | "\(.name)|\(.networkInterfaces[0].accessConfigs[0].natIP)|\(.networkInterfaces[0].networkIP)"
  ' | sort)"

  if [[ -z "$hosts" ]]; then
    echo "      hosts: {}"
    return
  fi

  while IFS='|' read -r name ip internal_ip; do
    [[ -n "$name" && -n "$ip" ]] || continue
    echo "        ${name}:"
    echo "          ansible_host: ${ip}"
    echo "          internal_ip: ${internal_ip}"
    echo "          node_role: ${role}"
  done <<< "$hosts"
}

{
  echo "all:"
  echo "  vars:"
  echo "    ansible_user: ubuntu"
  echo "    ansible_ssh_common_args: \"-o StrictHostKeyChecking=no\""
  echo "    k3s_version: \"${K3S_VERSION}\""
  echo "    cluster_name: ${CLUSTER}"
  echo "    cluster_profile: ${CLUSTER}"
  echo "    provisioner: gcp-compute"
  echo "    ingress_host: \"${ingress_host}\""
  echo "    k3s_api_host: \"${k3s_api_host}\""
  echo "    k3s_api_internal: \"${k3s_api_internal}\""
  echo "  children:"
  write_host_group "k3s_server" "server"
  write_host_group "k3s_agent" "agent"
} > "$OUTPUT"

echo "Inventory written: ${OUTPUT} (${instance_count} instance(s))"
