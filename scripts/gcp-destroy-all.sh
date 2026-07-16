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

DESTROY_FAILED=0

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
  (
    cd "$dir"
    terraform init -input=false
    if [[ "$AUTO_APPROVE" == "1" ]]; then
      terraform destroy -auto-approve -input=false
    else
      terraform destroy -input=false
    fi
  ) || {
    echo "ERROR: terraform destroy failed for ${module}" >&2
    DESTROY_FAILED=1
    return 1
  }
}

gcloud config set project "$GCP_PROJECT"

"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" pull

# Reverse apply order — continue after a module failure so remaining stacks still tear down
tf_destroy vpn-gateways-gcp || true
tf_destroy shared-services-gcp || true
tf_destroy cloud-services-gcp || true
tf_destroy primary-cluster-gcp || true

"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" push

if [[ "$DESTROY_FAILED" -ne 0 ]]; then
  die "One or more modules failed to destroy (see errors above). Fix IAM/state and re-run."
fi

if [[ "$DELETE_PROJECT" == "1" ]]; then
  log "Scheduling project deletion: ${GCP_PROJECT}"
  gcloud projects delete "$GCP_PROJECT" --quiet
  echo "Project deletion scheduled (can take a few minutes)."
else
  log "Resources destroyed. Project ${GCP_PROJECT} still exists."
  echo "To delete the project too: DELETE_PROJECT=1 ./scripts/gcp-destroy-all.sh"
fi

log "Teardown complete"
