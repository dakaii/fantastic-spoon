#!/usr/bin/env bash
# gcp-vpn-ci.sh — WireGuard VPN city gateway from GitHub Actions
#
# Requires env: GCP_PROJECT, SSH_PUBLIC_KEY, ADMIN_CIDR
# Optional: VPN_CITY (default us)
# Uploads client .conf as a workflow artifact from the caller.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export SKIP_AUTH=1
export FORCE_TFVARS="${FORCE_TFVARS:-1}"
export VPN_CITY="${VPN_CITY:-us}"

: "${GCP_PROJECT:?Set GCP_PROJECT}"
: "${SSH_PUBLIC_KEY:?Set SSH_PUBLIC_KEY}"
: "${ADMIN_CIDR:?Set ADMIN_CIDR}"

log() { echo "==> $*"; }

command -v wg >/dev/null 2>&1 || {
  echo "ERROR: wireguard-tools (wg) required on the runner" >&2
  exit 1
}

gcloud config set project "$GCP_PROJECT"

log "Pulling Terraform state from GCS (if any)"
"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" pull

log "Writing terraform.tfvars"
"${REPO_ROOT}/scripts/gcp-deploy.sh" init

log "VPN provision + WireGuard bootstrap"
export SKIP_AUTH=1
"${REPO_ROOT}/scripts/gcp-deploy.sh" vpn

log "Pushing Terraform state to GCS"
"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" push

CITY="$VPN_CITY"
CONF="${REPO_ROOT}/vpn-clients/${CITY}/laptop-${CITY}.conf"
if [[ -f "$CONF" ]]; then
  mkdir -p "${REPO_ROOT}/tmp/vpn-artifact"
  cp "$CONF" "${REPO_ROOT}/tmp/vpn-artifact/"
  # Public endpoint only — do not print private keys
  log "Client config ready for artifact upload: tmp/vpn-artifact/$(basename "$CONF")"
  terraform -chdir="${REPO_ROOT}/vpn-gateways-gcp" output -raw vpn_public_ip || true
else
  echo "ERROR: expected client config at ${CONF}" >&2
  exit 1
fi

log "VPN CI complete — download the workflow artifact and import into WireGuard"
