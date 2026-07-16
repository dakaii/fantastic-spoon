#!/usr/bin/env bash
# gcp-destroy-verify.sh — Pre/post checks for GCP destroy (CI + local)
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-destroy-verify.sh pre
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-destroy-verify.sh post
set -euo pipefail

PHASE="${1:?Usage: gcp-destroy-verify.sh <pre|post>}"
GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"
TFSTATE_BUCKET="${TFSTATE_BUCKET:-${GCP_PROJECT}-tfstate}"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

list_instances() {
  gcloud compute instances list --project="$GCP_PROJECT" \
    --format="table(name,zone,machineType,status)" 2>/dev/null || true
}

instance_count() {
  gcloud compute instances list --project="$GCP_PROJECT" --format="value(name)" 2>/dev/null | wc -l | tr -d ' '
}

state_object_count() {
  local n=0 module
  for module in primary-cluster-gcp cloud-services-gcp shared-services-gcp vpn-gateways-gcp; do
    if gcloud storage ls "gs://${TFSTATE_BUCKET}/${module}/terraform.tfstate" --project="$GCP_PROJECT" &>/dev/null; then
      n=$((n + 1))
    fi
  done
  echo "$n"
}

case "$PHASE" in
  pre)
    log "Instances before destroy:"
    list_instances
    COUNT="$(instance_count)"
    STATES="$(state_object_count)"
    log "Instance count: ${COUNT}; remote TF state objects: ${STATES}"
    if [[ "$COUNT" -gt 0 && "$STATES" -eq 0 ]]; then
      die "VMs exist but no Terraform state in gs://${TFSTATE_BUCKET}/.
Push from the machine that applied Terraform:
  GCP_PROJECT=${GCP_PROJECT} ./scripts/gcp-tfstate-sync.sh push
Or: GCP_PROJECT=${GCP_PROJECT} ./scripts/gcp-teardown.sh --gha"
    fi
    if [[ "$COUNT" -eq 0 && "$STATES" -eq 0 ]]; then
      log "Nothing to destroy (no VMs, no remote state)."
    fi
    ;;
  post)
    log "Instances after destroy:"
    list_instances
    COUNT="$(instance_count)"
    if [[ "$COUNT" -gt 0 ]]; then
      die "${COUNT} instance(s) still running after destroy.
Re-run with state pushed, or delete manually:
  gcloud compute instances list --project=${GCP_PROJECT}
Hint: HMAC 403 → ./scripts/gcp-setup-github-actions.sh --full"
    fi
    log "Verify OK — no compute instances remain."
    ;;
  *)
    die "Unknown phase '${PHASE}' (use pre|post)"
    ;;
esac
