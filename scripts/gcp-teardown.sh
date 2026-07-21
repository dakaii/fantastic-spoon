#!/usr/bin/env bash
# gcp-teardown.sh — One-shot stop-billing teardown (local or GitHub Actions)
#
# Handles the footguns from this project's destroy flow:
#   - gcloud account vs Application Default Credentials (Terraform uses ADC)
#   - local Terraform state must reach GCS before GHA destroy can see VMs
#   - prefer local state over a stale GCS pull
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-teardown.sh
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-teardown.sh --gha
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-teardown.sh --gha --watch
#   DELETE_PROJECT=1 GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-teardown.sh
#
# Env:
#   GCP_PROJECT     required
#   GCP_ACCOUNT     optional — passed to gcp-use-project.sh
#   DELETE_PROJECT  1 = also delete the GCP project (local and --gha)
#   SKIP_ADC_CHECK  1 = skip ADC email vs gcloud account check (local mode)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE=local
WATCH=0

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gha) MODE=gha ;;
    --local) MODE=local ;;
    --watch) WATCH=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

: "${GCP_PROJECT:?Set GCP_PROJECT}"

command -v gcloud >/dev/null 2>&1 || die "gcloud required"
if [[ "$MODE" == "local" ]]; then
  command -v terraform >/dev/null 2>&1 || die "terraform required for local teardown"
fi

# --- Account + project -------------------------------------------------------
if [[ -n "${GCP_ACCOUNT:-}" ]]; then
  GCP_PROJECT="$GCP_PROJECT" GCP_ACCOUNT="$GCP_ACCOUNT" \
    "${REPO_ROOT}/scripts/gcp-use-project.sh" >/dev/null
else
  gcloud config set project "$GCP_PROJECT" >/dev/null
fi

GCLOUD_ACCOUNT="$(gcloud config get-value account 2>/dev/null || true)"
[[ -n "$GCLOUD_ACCOUNT" && "$GCLOUD_ACCOUNT" != "(unset)" ]] || \
  die "No active gcloud account — run: gcloud auth login"

# --- ADC must match gcloud (Terraform uses ADC, not gcloud config) -------------
# Only required for local terraform destroy; --gha uses the CI service account.
adc_email() {
  local token email
  token="$(gcloud auth application-default print-access-token 2>/dev/null || true)"
  [[ -n "$token" ]] || return 1
  email="$(curl -fsS "https://www.googleapis.com/oauth2/v1/tokeninfo?access_token=${token}" 2>/dev/null \
    | sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' || true)"
  [[ -n "$email" ]] || return 1
  echo "$email"
}

if [[ "$MODE" == "local" && "${SKIP_ADC_CHECK:-0}" != "1" ]]; then
  ADC_EMAIL="$(adc_email || true)"
  if [[ -z "$ADC_EMAIL" ]]; then
    die "No Application Default Credentials. Terraform needs them:
  gcloud auth application-default login
# Sign in as ${GCLOUD_ACCOUNT}, then re-run this script."
  fi
  if [[ "$ADC_EMAIL" != "$GCLOUD_ACCOUNT" ]]; then
    die "ADC account (${ADC_EMAIL}) != gcloud account (${GCLOUD_ACCOUNT}).
Terraform will use ADC and hit 403s. Fix with:
  gcloud auth application-default login
# Choose ${GCLOUD_ACCOUNT} in the browser, then:
  gcloud auth application-default set-quota-project ${GCP_PROJECT}"
  fi
  gcloud auth application-default set-quota-project "$GCP_PROJECT" >/dev/null 2>&1 || true
  log "ADC matches gcloud account: ${GCLOUD_ACCOUNT}"
fi

# --- Ensure tfvars so destroy modules are not skipped (local mode) ------------
export SKIP_AUTH=1
export FORCE_TFVARS="${FORCE_TFVARS:-0}"
if [[ "$MODE" == "local" ]]; then
  if [[ ! -f "${REPO_ROOT}/primary-cluster-gcp/terraform.tfvars" ]] || \
     [[ ! -f "${REPO_ROOT}/cloud-services-gcp/terraform.tfvars" ]] || \
     [[ ! -f "${REPO_ROOT}/vpn-gateways-gcp/terraform.tfvars" ]]; then
    log "Writing missing terraform.tfvars via gcp-deploy.sh init"
    export FORCE_TFVARS=1
    export SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$(cat "${HOME}/.ssh/id_ed25519.pub" 2>/dev/null || echo "ssh-ed25519 placeholder")}"
    export ADMIN_CIDR="${ADMIN_CIDR:-127.0.0.1/32}"
    "${REPO_ROOT}/scripts/gcp-deploy.sh" init
  fi
fi

# --- Push local state so GHA (or a later pull) sees Mac-applied resources ----
log "Pushing local Terraform state to GCS (if any)"
"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" push

case "$MODE" in
  gha)
    command -v gh >/dev/null 2>&1 || die "gh required for --gha"
    REPO_SLUG="${GITHUB_REPOSITORY:-$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo dakaii/fantastic-spoon)}"
    log "Triggering GCP Destroy via GitHub Actions (${REPO_SLUG})"
    if [[ "${DELETE_PROJECT:-0}" == "1" ]]; then
      gh workflow run gcp-destroy.yml -R "$REPO_SLUG" -f delete_project=true
    else
      gh workflow run gcp-destroy.yml -R "$REPO_SLUG"
    fi
    echo "Watch: gh run watch -R ${REPO_SLUG}"
    if [[ "$WATCH" -eq 1 ]]; then
      gh run watch -R "$REPO_SLUG"
    fi
    log "After the run: gcloud compute instances list --project=${GCP_PROJECT}"
    ;;
  local)
    log "Destroying locally (prefer local state; pull only when missing)"
    export PREFER_LOCAL_STATE=1
    DELETE_PROJECT="${DELETE_PROJECT:-0}" "${REPO_ROOT}/scripts/gcp-destroy-all.sh"
    GCP_PROJECT="$GCP_PROJECT" "${REPO_ROOT}/scripts/gcp-destroy-verify.sh" post
    ;;
esac
