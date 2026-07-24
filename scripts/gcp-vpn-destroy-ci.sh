#!/usr/bin/env bash
# gcp-vpn-destroy-ci.sh — Tear down one VPN city gateway (GitHub Actions / local)
#
# Does NOT touch primary/standby/shared-services clusters.
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev VPN_CITY=us ./scripts/gcp-vpn-destroy-ci.sh
#   GCP_PROJECT=hybrid-k8s-dev VPN_CITY=hk ./scripts/gcp-vpn-destroy-ci.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${REPO_ROOT}/vpn-gateways-gcp"

export SKIP_AUTH=1
export FORCE_TFVARS="${FORCE_TFVARS:-1}"
export SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-ssh-ed25519 placeholder}"
export ADMIN_CIDR="${ADMIN_CIDR:-127.0.0.1/32}"
export VPN_CITY="${VPN_CITY:-us}"

# shellcheck source=vpn-city-lib.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/vpn-city-lib.sh"
vpn_city_resolve "$VPN_CITY"

: "${GCP_PROJECT:?Set GCP_PROJECT}"

log() { echo "==> $*"; }

command -v gcloud >/dev/null 2>&1 || { echo "ERROR: gcloud required" >&2; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo "ERROR: terraform required" >&2; exit 1; }

gcloud config set project "$GCP_PROJECT"

log "Pulling Terraform state from GCS (city=${VPN_CITY})"
VPN_CITY="$VPN_CITY" "${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" pull

log "Writing vpn-gateways-gcp/terraform.tfvars for city=${VPN_CITY}"
"${REPO_ROOT}/scripts/gcp-deploy.sh" init

if [[ ! -f "${TF_DIR}/terraform.tfvars" ]]; then
  log "No vpn terraform.tfvars — nothing to destroy"
  exit 0
fi

log "Destroying vpn-gateways-gcp city=${VPN_CITY} (WireGuard gateway VM + VPC)"
(
  cd "$TF_DIR"
  terraform init -input=false
  if terraform state list 2>/dev/null | grep -q .; then
    terraform destroy -auto-approve -input=false
  else
    log "No Terraform state — gateway may already be gone"
  fi
)

log "Pushing empty/destroyed state to GCS (city=${VPN_CITY})"
VPN_CITY="$VPN_CITY" "${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" push

log "VPN city ${VPN_CITY} destroyed. Local keys remain under vpn-clients/${VPN_CITY}/ (gitignored)."
echo "Remove locally: rm -rf vpn-clients/${VPN_CITY}"
echo "Other cities are untouched — destroy them with VPN_CITY=<city> separately."
