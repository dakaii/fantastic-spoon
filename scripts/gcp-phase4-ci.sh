#!/usr/bin/env bash
# gcp-phase4-ci.sh — Phase 4 from GitHub Actions (no local gcloud login)
#
# Requires env: GCP_PROJECT, SSH_PUBLIC_KEY, ADMIN_CIDR
# Optional: DOMAIN_NAME, APP_SUBDOMAIN, CREATE_FIRESTORE_DATABASE
# Uses secrets.GCP_SA_KEY via google-github-actions/auth (ADC for Terraform).
#
# Needs primary+standby state in GCS (sync from prior Deploy / Phase 2 / local push).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export SKIP_AUTH=1
export FORCE_TFVARS="${FORCE_TFVARS:-1}"

: "${GCP_PROJECT:?Set GCP_PROJECT}"
: "${SSH_PUBLIC_KEY:?Set SSH_PUBLIC_KEY}"
: "${ADMIN_CIDR:?Set ADMIN_CIDR}"

log() { echo "==> $*"; }

gcloud config set project "$GCP_PROJECT"

log "Pulling Terraform state from GCS (primary/standby/shared required)"
"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" pull

if [[ ! -f "${REPO_ROOT}/primary-cluster-gcp/terraform.tfstate" ]]; then
  echo "ERROR: No primary-cluster-gcp state in GCS — run Deploy All or Phase 1 first, then gcp-tfstate-sync.sh push" >&2
  exit 1
fi
if [[ ! -f "${REPO_ROOT}/cloud-services-gcp/terraform.tfstate" ]]; then
  echo "ERROR: No cloud-services-gcp state in GCS — run Phase 2 first, then gcp-tfstate-sync.sh push" >&2
  exit 1
fi

log "Writing terraform.tfvars from GitHub secrets / inputs"
"${REPO_ROOT}/scripts/gcp-deploy.sh" init

# Ensure primary API is reachable by Cloud Function (ADMIN_CIDR is usually 0.0.0.0/0 in GHA)
if [[ -f "${REPO_ROOT}/primary-cluster-gcp/terraform.tfvars" ]]; then
  if ! grep -q 'k3s_api_source_ranges' "${REPO_ROOT}/primary-cluster-gcp/terraform.tfvars"; then
    echo "k3s_api_source_ranges = [\"${ADMIN_CIDR}\"]" >> "${REPO_ROOT}/primary-cluster-gcp/terraform.tfvars"
  fi
  log "Refreshing primary firewall for witness reachability"
  (
    cd "${REPO_ROOT}/primary-cluster-gcp"
    terraform init -input=false
    terraform apply -auto-approve -input=false \
      -target=google_compute_firewall.primary_k3s_api
  )
fi

log "Enabling GCP APIs (includes Gen2)"
"${REPO_ROOT}/scripts/gcp-enable-apis.sh"

log "Phase 4 — shared-services-gcp"
export SKIP_AUTH=1
"${REPO_ROOT}/scripts/gcp-deploy.sh" failover

log "Pushing Terraform state to GCS"
"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" push

log "Phase 4 complete"
terraform -chdir="${REPO_ROOT}/shared-services-gcp" output 2>/dev/null || true
echo "Next: docs/PHASE-4-RUNBOOK.md (NS delegation if DOMAIN_NAME set; ./scripts/failover-gcp.sh for apps)"
