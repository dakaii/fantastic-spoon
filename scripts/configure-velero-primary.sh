#!/usr/bin/env bash
# configure-velero-primary.sh — Point primary Velero at the GCS bucket from Phase 2
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
META="${REPO_ROOT}/ansible/inventory/standby-hosts.meta.json"
INVENTORY="${REPO_ROOT}/ansible/inventory/primary-hosts.yml"

log() { echo "==> $*"; }

if [[ ! -f "$META" ]]; then
  log "No ${META} — skipping Velero config on primary"
  exit 0
fi

# Always refresh primary inventory from live GCE when possible — ephemeral NAT
# IPs change often and a stale primary-hosts.yml causes SSH timeouts / false failures.
if command -v gcloud >/dev/null 2>&1; then
  if [[ -z "${GCP_PROJECT:-}" ]]; then
    GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  fi
  if [[ -n "${GCP_PROJECT:-}" ]]; then
    log "Refreshing primary inventory from GCE (project: ${GCP_PROJECT})"
    GCP_PROJECT="${GCP_PROJECT}" "${REPO_ROOT}/scripts/generate-gcp-inventory.sh" primary
  elif [[ ! -f "$INVENTORY" ]]; then
    echo "ERROR: Missing ${INVENTORY} and GCP_PROJECT is unset (cannot generate inventory)" >&2
    exit 1
  else
    log "WARN: gcloud has no project set — using existing ${INVENTORY} (may be stale)"
  fi
elif [[ ! -f "$INVENTORY" ]]; then
  echo "ERROR: Missing ${INVENTORY} and gcloud is unavailable" >&2
  exit 1
fi

# shellcheck source=inventory-utils.sh
source "${REPO_ROOT}/scripts/inventory-utils.sh"
cp_host="$(inventory_first_control_plane_ip "$INVENTORY")"
if [[ -n "$cp_host" ]]; then
  log "Primary control plane from inventory: ${cp_host}"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
      "ubuntu@${cp_host}" true 2>/dev/null; then
    echo "ERROR: Cannot SSH to primary CP ${cp_host}" >&2
    echo "  Check admin_cidr / firewall, or: GCP_PROJECT=... ./scripts/generate-gcp-inventory.sh primary" >&2
    exit 1
  fi
fi

bucket=$(jq -r '.velero_bucket // empty' "$META")
key=$(jq -r '.velero_access_key // empty' "$META")
secret=$(jq -r '.velero_secret_key // empty' "$META")
vprovider=$(jq -r '.velero_provider // "gcp"' "$META")
vregion=$(jq -r '.velero_region // "auto"' "$META")

if [[ -z "$bucket" || -z "$key" || -z "$secret" ]]; then
  log "Velero credentials missing in meta — skipping primary Velero config"
  exit 0
fi

log "Configuring Velero on primary (bucket: ${bucket})"
(
  cd "${REPO_ROOT}/ansible"
  # --tags addons: skip common/k3s; --limit first server only
  ansible-playbook \
    -i "inventory/primary-hosts.yml" \
    playbooks/site.yml \
    --tags addons \
    --limit 'k3s_server[0]' \
    -e cluster_profile=primary \
    -e cluster_name=primary \
    -e provisioner=gcp-compute \
    -e "velero_bucket=${bucket}" \
    -e "velero_access_key=${key}" \
    -e "velero_secret_key=${secret}" \
    -e "velero_provider=${vprovider}" \
    -e "velero_region=${vregion}"
)
