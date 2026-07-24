#!/usr/bin/env bash
# seed-standby-kubeconfig.sh — Put standby k3s kubeconfig into Secret Manager for Level C
#
# Prerequisites:
#   - Standby cluster bootstrapped (Phase 2)
#   - SSH to standby CP as ubuntu
#   - gcloud auth with permission to create/add Secret Manager secrets
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/seed-standby-kubeconfig.sh
#
# Then enable automation:
#   enable_level_c_automation = true  # in shared-services-gcp/terraform.tfvars
#   # lab: k3s_api_source_ranges = ["0.0.0.0/0"] in cloud-services-gcp
#   terraform -chdir=shared-services-gcp apply
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/inventory-utils.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/inventory-utils.sh"

GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"
SECRET_ID="${STANDBY_KUBECONFIG_SECRET:-hybrid-k8s-standby-kubeconfig}"
INV="${REPO_ROOT}/ansible/inventory/standby-hosts.yml"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v gcloud >/dev/null 2>&1 || die "gcloud required"
command -v ssh >/dev/null 2>&1 || die "ssh required"

gcloud config set project "$GCP_PROJECT" >/dev/null

# Refresh inventory when possible
if command -v gcloud >/dev/null 2>&1; then
  log "Refreshing standby inventory from GCE"
  GCP_PROJECT="$GCP_PROJECT" "${REPO_ROOT}/scripts/generate-gcp-inventory.sh" standby || \
    log "WARN: inventory generate failed — using existing ${INV}"
fi

[[ -f "$INV" ]] || die "Missing ${INV} — bootstrap standby first"

CP_IP="$(inventory_first_control_plane_ip "$INV" 2>/dev/null || true)"
[[ -n "$CP_IP" ]] || die "Could not read standby control-plane IP from ${INV}"

log "Fetching kubeconfig from ubuntu@${CP_IP}"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 "ubuntu@${CP_IP}" \
  "sudo cat /etc/rancher/k3s/k3s.yaml" >"$TMP" || die "SSH/kubeconfig fetch failed"

# Point at public NAT IP (k3s.yaml uses 127.0.0.1)
if [[ "$(uname -s)" == "Darwin" ]]; then
  sed -i '' "s/127.0.0.1/${CP_IP}/g" "$TMP"
else
  sed -i "s/127.0.0.1/${CP_IP}/g" "$TMP"
fi

# Skip TLS verify for lab (self-signed) — activate CF also disables verify_ssl
if ! grep -q 'insecure-skip-tls-verify' "$TMP"; then
  # Insert under cluster: entry — portable-ish: append clusters insecure flag via yq if present
  if command -v yq >/dev/null 2>&1; then
    yq -i '.clusters[0].cluster."insecure-skip-tls-verify"=true | del(.clusters[0].cluster."certificate-authority-data")' "$TMP"
  else
    log "WARN: yq not installed — leaving cert data; activate CF sets verify_ssl=False anyway"
  fi
fi

chmod 600 "$TMP"

if gcloud secrets describe "$SECRET_ID" --project="$GCP_PROJECT" &>/dev/null; then
  log "Adding new secret version to ${SECRET_ID}"
  gcloud secrets versions add "$SECRET_ID" --project="$GCP_PROJECT" --data-file="$TMP"
else
  log "Creating secret ${SECRET_ID}"
  gcloud secrets create "$SECRET_ID" --project="$GCP_PROJECT" --replication-policy=automatic --data-file="$TMP"
fi

log "Seeded ${SECRET_ID} (standby API https://${CP_IP}:6443)"
cat <<EOF

Next:
  1. Open standby API for Cloud Function egress (lab):
       # cloud-services-gcp/terraform.tfvars
       k3s_api_source_ranges = ["0.0.0.0/0"]
       terraform -chdir=cloud-services-gcp apply

  2. Enable Level C in shared-services-gcp/terraform.tfvars:
       enable_level_c_automation = true
       terraform -chdir=shared-services-gcp apply

  3. Drill (optional):
       ./scripts/failover-gcp.sh status
       # Or invoke activate URI with an identity token (see PHASE-4-RUNBOOK.md)

EOF
