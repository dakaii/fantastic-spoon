#!/usr/bin/env bash
# gcp-use-project.sh — Switch gcloud account + project for this repo
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-use-project.sh
#   GCP_PROJECT=hybrid-k8s-dev GCP_ACCOUNT=you@gmail.com ./scripts/gcp-use-project.sh
#
# Lists credentialed accounts if GCP_ACCOUNT is unset and multiple exist.
set -euo pipefail

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: '$1' not found" >&2
    exit 1
  }
}

require_cmd gcloud

GCP_PROJECT="${GCP_PROJECT:-}"
GCP_ACCOUNT="${GCP_ACCOUNT:-}"

if [[ -z "$GCP_PROJECT" ]]; then
  CURRENT_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -n "$CURRENT_PROJECT" && "$CURRENT_PROJECT" != "(unset)" ]]; then
    read -r -p "GCP project ID [${CURRENT_PROJECT}]: " REPLY
    GCP_PROJECT="${REPLY:-$CURRENT_PROJECT}"
  else
    read -r -p "GCP project ID: " GCP_PROJECT
  fi
fi

[[ -n "$GCP_PROJECT" ]] || {
  echo "ERROR: GCP project ID is required" >&2
  exit 1
}

if [[ -z "$GCP_ACCOUNT" ]]; then
  accounts=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && accounts+=("$line")
  done < <(gcloud auth list --filter=status:ACTIVE --format="value(account)")
  if [[ "${#accounts[@]}" -eq 0 ]]; then
    echo "No active gcloud accounts. Run: ./scripts/gcp-auth.sh" >&2
    exit 1
  fi
  if [[ "${#accounts[@]}" -eq 1 ]]; then
    GCP_ACCOUNT="${accounts[0]}"
  else
    echo "Active gcloud accounts:"
    gcloud auth list --filter=status:ACTIVE --format="table(account,status)"
    read -r -p "Account to use: " GCP_ACCOUNT
  fi
fi

[[ -n "$GCP_ACCOUNT" ]] || {
  echo "ERROR: GCP account is required" >&2
  exit 1
}

echo "==> Using account:  ${GCP_ACCOUNT}"
echo "==> Using project: ${GCP_PROJECT}"

gcloud config set account "$GCP_ACCOUNT"
gcloud config set project "$GCP_PROJECT"

if gcloud auth application-default print-access-token >/dev/null 2>&1; then
  gcloud auth application-default set-quota-project "$GCP_PROJECT" 2>/dev/null || true
  # Terraform uses ADC, not gcloud config — warn on mismatch
  token="$(gcloud auth application-default print-access-token 2>/dev/null || true)"
  if [[ -n "$token" ]]; then
    adc_email="$(curl -fsS "https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=${token}" 2>/dev/null \
      | sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
    if [[ -n "$adc_email" && "$adc_email" != "$GCP_ACCOUNT" ]]; then
      echo ""
      echo "WARNING: Application Default Credentials are ${adc_email},"
      echo "         but gcloud account is ${GCP_ACCOUNT}."
      echo "Terraform will use ADC and may 403. Fix before terraform apply/destroy:"
      echo "  gcloud auth application-default login   # choose ${GCP_ACCOUNT}"
      echo "  gcloud auth application-default set-quota-project ${GCP_PROJECT}"
      echo ""
    fi
  fi
else
  echo ""
  echo "WARNING: No Application Default Credentials. Terraform needs:"
  echo "  gcloud auth application-default login"
  echo ""
fi

echo ""
echo "==> Verifying access"
gcloud compute instances list --project="$GCP_PROJECT" --format="table(name,zone,machineType,status)"

echo ""
echo "Done. Teardown (stop billing):"
echo "  GCP_PROJECT=${GCP_PROJECT} ./scripts/gcp-teardown.sh"
echo "  GCP_PROJECT=${GCP_PROJECT} ./scripts/gcp-teardown.sh --gha --watch"
