#!/usr/bin/env bash
# gcp-auth.sh — Sign in to GCP via browser (no credentials stored in this repo)
#
# Stores credentials locally:
#   ~/.config/gcloud/              — gcloud CLI session
#   ~/.config/gcloud/application_default_credentials.json — Terraform ADC
#
# Your email is never written to git. Run this once per machine (or when tokens expire).
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found. Install Google Cloud SDK: https://cloud.google.com/sdk/docs/install"
    exit 1
  }
}

require_cmd gcloud

echo "==> GCP browser login"
echo "    A browser window will open. Sign in with your Google account."
echo "    (Your email stays on your machine — nothing is saved to GitHub.)"
echo ""

# CLI session — list projects, enable APIs, etc.
gcloud auth login

# Application Default Credentials — used by Terraform
gcloud auth application-default login

echo ""
echo "==> Authenticated accounts:"
gcloud auth list --filter=status:ACTIVE --format="table(account,status)"

CURRENT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
if [[ -n "$CURRENT_PROJECT" && "$CURRENT_PROJECT" != "(unset)" ]]; then
  echo ""
  echo "Default project: ${CURRENT_PROJECT}"
else
  echo ""
  echo "Tip: set a default project with:"
  echo "  gcloud config set project YOUR_PROJECT_ID"
fi

echo ""
echo "Done. Run ./scripts/gcp-deploy.sh init to create local terraform.tfvars files."
