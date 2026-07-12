#!/usr/bin/env bash
# gcp-project-create.sh — Create GCP project locally (NOT a GitHub Action)
#
# GitHub Actions cannot reliably create projects (needs org Project Creator +
# billing permissions). Run this once on your Mac, then use GHA for deploy/destroy.
#   - resourcemanager.projects.create (org/folder) OR use an existing empty project ID
#   - billing.resourceAssociations.create on the billing account
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-test-001 \
#   BILLING_ACCOUNT_ID=012345-678901-ABCDEF \
#   ./scripts/gcp-project-create.sh
#
# Optional:
#   GCP_FOLDER_ID=folders/123456789
#   GCP_ORG_ID=organizations/123456789
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

GCP_PROJECT="${GCP_PROJECT:?Set GCP_PROJECT (new project ID)}"
BILLING_ACCOUNT_ID="${BILLING_ACCOUNT_ID:?Set BILLING_ACCOUNT_ID (012345-678901-ABCDEF)}"
GCP_REGION="${GCP_REGION:-us-central1}"
TFSTATE_BUCKET="${TFSTATE_BUCKET:-${GCP_PROJECT}-tfstate}"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found"
}

require_cmd gcloud

create_args=(--name="Hybrid K8s ${GCP_PROJECT}" --project="$GCP_PROJECT")

if [[ -n "${GCP_FOLDER_ID:-}" ]]; then
  create_args+=(--folder="$GCP_FOLDER_ID")
elif [[ -n "${GCP_ORG_ID:-}" ]]; then
  create_args+=(--organization="$GCP_ORG_ID")
fi

if gcloud projects describe "$GCP_PROJECT" &>/dev/null; then
  log "Project already exists: ${GCP_PROJECT}"
else
  log "Creating project: ${GCP_PROJECT}"
  gcloud projects create "${create_args[@]}"
fi

log "Linking billing account"
gcloud billing projects link "$GCP_PROJECT" --billing-account="$BILLING_ACCOUNT_ID"

gcloud config set project "$GCP_PROJECT"

"${REPO_ROOT}/scripts/gcp-enable-apis.sh"

if gcloud storage buckets describe "gs://${TFSTATE_BUCKET}" &>/dev/null; then
  log "State bucket already exists: gs://${TFSTATE_BUCKET}"
else
  log "Creating Terraform state bucket: gs://${TFSTATE_BUCKET}"
  gcloud storage buckets create "gs://${TFSTATE_BUCKET}" \
    --project="$GCP_PROJECT" \
    --location="$GCP_REGION" \
    --uniform-bucket-level-access
fi

echo ""
echo "========================================"
echo " Project ready: ${GCP_PROJECT}"
echo " State bucket:   gs://${TFSTATE_BUCKET}"
echo "========================================"
echo ""
echo "Next:"
echo "  1. Run ./scripts/gcp-setup-github-actions.sh --full --push-secrets"
echo "  2. GitHub Actions → GCP Lifecycle → deploy-all"
echo "     Or locally: GCP_PROJECT=${GCP_PROJECT} ./scripts/gcp-deploy-ci.sh"
