#!/usr/bin/env bash
# gcp-phase2-ci.sh — Phase 2 from GitHub Actions (no local gcloud login)
#
# Requires env: GCP_PROJECT, SSH_PUBLIC_KEY, ADMIN_CIDR
# Uses secrets.GCP_SA_KEY via google-github-actions/auth (ADC for Terraform).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export SKIP_AUTH=1
export FORCE_TFVARS="${FORCE_TFVARS:-1}"

: "${GCP_PROJECT:?Set GCP_PROJECT}"
: "${SSH_PUBLIC_KEY:?Set SSH_PUBLIC_KEY}"
: "${ADMIN_CIDR:?Set ADMIN_CIDR}"

log() { echo "==> $*"; }

gcloud config set project "$GCP_PROJECT"

log "Pulling Terraform state from GCS (if any)"
"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" pull

log "Writing terraform.tfvars from GitHub secrets"
"${REPO_ROOT}/scripts/gcp-deploy.sh" init

log "Enabling GCP APIs"
"${REPO_ROOT}/scripts/gcp-enable-apis.sh"

log "Phase 2 — provision standby cluster + GCS backups"
"${REPO_ROOT}/scripts/provision.sh" standby

log "Pushing Terraform state to GCS"
"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" push

if [[ ! -f "${REPO_ROOT}/config/clusters.yaml" ]]; then
  cp "${REPO_ROOT}/config/clusters.example.yaml" "${REPO_ROOT}/config/clusters.yaml"
fi

log "Bootstrap standby cluster (Ansible)"
"${REPO_ROOT}/scripts/bootstrap-cluster.sh" standby

if [[ "${SKIP_VELERO:-}" != "1" ]]; then
  log "Configure Velero on primary"
  "${REPO_ROOT}/scripts/configure-velero-primary.sh"
else
  log "Skipping Velero on primary (SKIP_VELERO=1)"
fi

log "Phase 2 complete"
terraform -chdir="${REPO_ROOT}/cloud-services-gcp" output standby_lb_ip 2>/dev/null || true
