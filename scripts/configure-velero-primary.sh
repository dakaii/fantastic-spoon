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

if [[ ! -f "$INVENTORY" ]]; then
  if [[ -z "${GCP_PROJECT:-}" ]]; then
    echo "ERROR: Missing ${INVENTORY} and GCP_PROJECT is unset (cannot generate inventory)" >&2
    exit 1
  fi
  log "Generating primary inventory from GCE"
  "${REPO_ROOT}/scripts/generate-gcp-inventory.sh" primary
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
  ansible-playbook \
    -i "inventory/primary-hosts.yml" \
    playbooks/site.yml \
    -e cluster_profile=primary \
    -e cluster_name=primary \
    -e provisioner=gcp-compute \
    -e "velero_bucket=${bucket}" \
    -e "velero_access_key=${key}" \
    -e "velero_secret_key=${secret}" \
    -e "velero_provider=${vprovider}" \
    -e "velero_region=${vregion}"
)
