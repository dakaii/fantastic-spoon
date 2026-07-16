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
# When 1: keep existing local terraform.tfstate; only pull modules with no local state.
# Avoids clobbering a Mac apply with an empty/stale GCS object before destroy.
PREFER_LOCAL_STATE="${PREFER_LOCAL_STATE:-0}"

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

sync_state_before_destroy() {
  local module local_file
  if [[ "$PREFER_LOCAL_STATE" != "1" ]]; then
    "${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" pull
    return
  fi

  log "Prefer local state — pull only modules with no local terraform.tfstate"
  # Ensure bucket exists / pull empty modules via selective pull
  for module in vpn-gateways-gcp shared-services-gcp cloud-services-gcp primary-cluster-gcp; do
    local_file="${REPO_ROOT}/${module}/terraform.tfstate"
    if [[ -f "$local_file" ]]; then
      log "Keep local state: ${module}"
    else
      # Pull single module by temporarily using sync script's pull for all is coarse;
      # call gcloud directly for the missing one.
      local uri="gs://${GCP_PROJECT}-tfstate/${module}/terraform.tfstate"
      mkdir -p "${REPO_ROOT}/${module}"
      if gcloud storage cp "$uri" "$local_file" --project="$GCP_PROJECT" 2>/dev/null; then
        log "Pulled state: ${module}"
      else
        log "No remote or local state: ${module}"
        rm -f "$local_file"
      fi
    fi
  done
}

gcloud config set project "$GCP_PROJECT"

sync_state_before_destroy

# Reverse apply order — continue after a module failure so remaining stacks still tear down
tf_destroy vpn-gateways-gcp || true
tf_destroy shared-services-gcp || true
tf_destroy cloud-services-gcp || true
tf_destroy primary-cluster-gcp || true

"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" push

if [[ "$DESTROY_FAILED" -ne 0 ]]; then
  die "One or more modules failed to destroy (see errors above). Fix IAM/state and re-run.
Hint: HMAC 403 → GCP_PROJECT=${GCP_PROJECT} ./scripts/gcp-setup-github-actions.sh --full
      ADC mismatch → gcloud auth application-default login (same account as gcloud)"
fi

if [[ "$DELETE_PROJECT" == "1" ]]; then
  log "Scheduling project deletion: ${GCP_PROJECT}"
  gcloud projects delete "$GCP_PROJECT" --quiet
  echo "Project deletion scheduled (can take a few minutes)."
else
  log "Resources destroyed. Project ${GCP_PROJECT} still exists."
  echo "To delete the project too: DELETE_PROJECT=1 ./scripts/gcp-destroy-all.sh"
  echo "Or one-shot: GCP_PROJECT=${GCP_PROJECT} ./scripts/gcp-teardown.sh"
fi

log "Teardown complete"
