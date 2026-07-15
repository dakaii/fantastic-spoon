#!/usr/bin/env bash
# gcp-destroy-all.sh — Tear down all Terraform-managed GCP resources
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-destroy-all.sh
#   DELETE_PROJECT=1 GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-destroy-all.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT}"
DELETE_PROJECT="${DELETE_PROJECT:-0}"
AUTO_APPROVE="${AUTO_APPROVE:-1}"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

tf_destroy() {
  local module="$1"
  local dir="${REPO_ROOT}/${module}"
  local tfvars="${dir}/terraform.tfvars"

  [[ -d "$dir" ]] || return 0
  [[ -f "$tfvars" ]] || {
    log "Skip ${module} (no terraform.tfvars)"
    return 0
  }

  log "Destroying ${module}"
  cd "$dir"
  terraform init -input=false

  if [[ "$AUTO_APPROVE" == "1" ]]; then
    terraform destroy -auto-approve -input=false || true
  else
    terraform destroy -input=false
  fi
}

gcloud config set project "$GCP_PROJECT"

"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" pull

# Reverse apply order
tf_destroy vpn-gateways-gcp
tf_destroy shared-services-gcp
tf_destroy cloud-services-gcp
tf_destroy primary-cluster-gcp

"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" push

if [[ "$DELETE_PROJECT" == "1" ]]; then
  log "Scheduling project deletion: ${GCP_PROJECT}"
  gcloud projects delete "$GCP_PROJECT" --quiet
  echo "Project deletion scheduled (can take a few minutes)."
else
  log "Resources destroyed. Project ${GCP_PROJECT} still exists."
  echo "To delete the project too: DELETE_PROJECT=1 ./scripts/gcp-destroy-all.sh"
fi

log "Teardown complete"
