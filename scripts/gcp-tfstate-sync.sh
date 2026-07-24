#!/usr/bin/env bash
# gcp-tfstate-sync.sh — Pull/push Terraform state via GCS for CI lifecycle runs
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-tfstate-sync.sh pull
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-tfstate-sync.sh push
#
# VPN gateways use per-city state keys:
#   gs://$BUCKET/vpn-gateways-gcp/<city>/terraform.tfstate
# Set VPN_CITY to sync one city into vpn-gateways-gcp/terraform.tfstate locally.
# Without VPN_CITY, pull/push syncs all known cities (us, hk); local file matches VPN_CITY or us.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:?Usage: gcp-tfstate-sync.sh <pull|push>}"

GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"
TFSTATE_BUCKET="${TFSTATE_BUCKET:-${GCP_PROJECT}-tfstate}"

# shellcheck source=vpn-city-lib.sh
# shellcheck disable=SC1091
source "${REPO_ROOT}/scripts/vpn-city-lib.sh"

CLUSTER_MODULES=(
  primary-cluster-gcp
  cloud-services-gcp
  shared-services-gcp
)

log() { echo "==> $*"; }

ensure_bucket() {
  if gcloud storage buckets describe "gs://${TFSTATE_BUCKET}" --project="$GCP_PROJECT" &>/dev/null; then
    return
  fi
  log "Creating state bucket gs://${TFSTATE_BUCKET}"
  gcloud storage buckets create "gs://${TFSTATE_BUCKET}" \
    --project="$GCP_PROJECT" \
    --location="${GCP_REGION:-us-central1}" \
    --uniform-bucket-level-access
}

pull_uri() {
  local uri="$1" local_file="$2" label="$3"
  mkdir -p "$(dirname "$local_file")"
  if gcloud storage cp "$uri" "$local_file" --project="$GCP_PROJECT" 2>/dev/null; then
    log "Pulled state: ${label}"
  else
    log "No remote state yet: ${label}"
    rm -f "$local_file"
  fi
}

push_uri() {
  local uri="$1" local_file="$2" label="$3"
  if [[ ! -f "$local_file" ]]; then
    log "Skip push (no local state): ${label}"
    return
  fi
  gcloud storage cp "$local_file" "$uri" --project="$GCP_PROJECT"
  log "Pushed state: ${label}"
}

pull_cluster_module() {
  local module="$1"
  pull_uri \
    "gs://${TFSTATE_BUCKET}/${module}/terraform.tfstate" \
    "${REPO_ROOT}/${module}/terraform.tfstate" \
    "$module"
}

push_cluster_module() {
  local module="$1"
  push_uri \
    "gs://${TFSTATE_BUCKET}/${module}/terraform.tfstate" \
    "${REPO_ROOT}/${module}/terraform.tfstate" \
    "$module"
}

# Legacy single-key location (pre multi-city) — migrate into us/ on pull if present
pull_vpn_cities() {
  local local_vpn="${REPO_ROOT}/vpn-gateways-gcp/terraform.tfstate"
  local active_city="${VPN_CITY:-us}"
  local city key uri staging legacy

  legacy="gs://${TFSTATE_BUCKET}/vpn-gateways-gcp/terraform.tfstate"
  staging="$(mktemp)"
  if gcloud storage cp "$legacy" "$staging" --project="$GCP_PROJECT" 2>/dev/null; then
    log "Found legacy VPN state — copying to vpn-gateways-gcp/us/ (and keeping local for us)"
    gcloud storage cp "$staging" "gs://${TFSTATE_BUCKET}/vpn-gateways-gcp/us/terraform.tfstate" \
      --project="$GCP_PROJECT" 2>/dev/null || true
  fi
  rm -f "$staging"

  if [[ -n "${VPN_CITY:-}" ]]; then
    key="$(vpn_city_state_gcs_key "$VPN_CITY")"
    pull_uri "gs://${TFSTATE_BUCKET}/${key}" "$local_vpn" "vpn-gateways-gcp/${VPN_CITY}"
    return
  fi

  # Sync all known cities into side files; active city (default us) → working tfstate
  for city in $(vpn_city_known); do
    key="$(vpn_city_state_gcs_key "$city")"
    uri="gs://${TFSTATE_BUCKET}/${key}"
    if [[ "$city" == "$active_city" ]]; then
      pull_uri "$uri" "$local_vpn" "vpn-gateways-gcp/${city}"
    else
      pull_uri "$uri" "${REPO_ROOT}/vpn-gateways-gcp/.states/${city}/terraform.tfstate" \
        "vpn-gateways-gcp/${city}"
    fi
  done
}

push_vpn_cities() {
  local local_vpn="${REPO_ROOT}/vpn-gateways-gcp/terraform.tfstate"
  local active_city="${VPN_CITY:-}"
  local city key

  # If VPN_CITY set, push working tree as that city
  if [[ -n "$active_city" ]]; then
    key="$(vpn_city_state_gcs_key "$active_city")"
    push_uri "gs://${TFSTATE_BUCKET}/${key}" "$local_vpn" "vpn-gateways-gcp/${active_city}"
    return
  fi

  # Infer city from local state outputs when possible
  if [[ -f "$local_vpn" ]] && command -v terraform >/dev/null 2>&1; then
    active_city="$(terraform -chdir="${REPO_ROOT}/vpn-gateways-gcp" output -raw vpn_city 2>/dev/null || echo us)"
  else
    active_city="us"
  fi
  key="$(vpn_city_state_gcs_key "$active_city")"
  push_uri "gs://${TFSTATE_BUCKET}/${key}" "$local_vpn" "vpn-gateways-gcp/${active_city}"

  for city in $(vpn_city_known); do
    [[ "$city" == "$active_city" ]] && continue
    local side="${REPO_ROOT}/vpn-gateways-gcp/.states/${city}/terraform.tfstate"
    key="$(vpn_city_state_gcs_key "$city")"
    push_uri "gs://${TFSTATE_BUCKET}/${key}" "$side" "vpn-gateways-gcp/${city}"
  done
}

case "$ACTION" in
  pull)
    ensure_bucket
    for module in "${CLUSTER_MODULES[@]}"; do
      pull_cluster_module "$module"
    done
    pull_vpn_cities
    ;;
  push)
    ensure_bucket
    for module in "${CLUSTER_MODULES[@]}"; do
      push_cluster_module "$module"
    done
    push_vpn_cities
    ;;
  *)
    echo "ERROR: Unknown action '${ACTION}' (use pull or push)" >&2
    exit 1
    ;;
esac
