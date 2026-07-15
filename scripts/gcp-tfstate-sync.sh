#!/usr/bin/env bash
# gcp-tfstate-sync.sh — Pull/push Terraform state via GCS for CI lifecycle runs
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-tfstate-sync.sh pull
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-tfstate-sync.sh push
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ACTION="${1:?Usage: gcp-tfstate-sync.sh <pull|push>}"

GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"
TFSTATE_BUCKET="${TFSTATE_BUCKET:-${GCP_PROJECT}-tfstate}"

MODULES=(
  primary-cluster-gcp
  cloud-services-gcp
  shared-services-gcp
  vpn-gateways-gcp
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

pull_module() {
  local module="$1"
  local local_file="${REPO_ROOT}/${module}/terraform.tfstate"
  local uri="gs://${TFSTATE_BUCKET}/${module}/terraform.tfstate"

  mkdir -p "$(dirname "$local_file")"
  if gcloud storage cp "$uri" "$local_file" --project="$GCP_PROJECT" 2>/dev/null; then
    log "Pulled state: ${module}"
  else
    log "No remote state yet: ${module}"
    rm -f "$local_file"
  fi
}

push_module() {
  local module="$1"
  local local_file="${REPO_ROOT}/${module}/terraform.tfstate"
  local uri="gs://${TFSTATE_BUCKET}/${module}/terraform.tfstate"

  if [[ ! -f "$local_file" ]]; then
    log "Skip push (no local state): ${module}"
    return
  fi
  gcloud storage cp "$local_file" "$uri" --project="$GCP_PROJECT"
  log "Pushed state: ${module}"
}

case "$ACTION" in
  pull)
    ensure_bucket
    for module in "${MODULES[@]}"; do
      pull_module "$module"
    done
    ;;
  push)
    ensure_bucket
    for module in "${MODULES[@]}"; do
      push_module "$module"
    done
    ;;
  *)
    echo "ERROR: Unknown action '${ACTION}' (use pull or push)" >&2
    exit 1
    ;;
esac
