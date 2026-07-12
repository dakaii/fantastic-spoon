#!/usr/bin/env bash
# gcp-setup-github-actions.sh — Create GCP service account + push GitHub Actions secrets
#
# Run once on your Mac (or Cloud Shell) after: gcloud auth login
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-setup-github-actions.sh
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-setup-github-actions.sh --push-secrets
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-setup-github-actions.sh --full --push-secrets
#
# Options:
#   --push-secrets   Upload secrets to GitHub via gh CLI (requires gh auth login)
#   --full           Grant Compute Admin + Storage Admin (for gcp-deploy.yml infra workflow)
#                    Default: Compute Viewer only (enough for gcp-bootstrap.yml)
#   --force-key      Create a new SA key even if one exists locally
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SA_ID="${SA_ID:-github-actions}"
SA_NAME="${SA_NAME:-GitHub Actions}"
KEY_DIR="${REPO_ROOT}/.secrets"
KEY_FILE="${KEY_DIR}/github-actions-sa-key.json"
SSH_KEY="${SSH_PRIVATE_KEY_PATH:-${HOME}/.ssh/id_ed25519}"

PUSH_SECRETS=0
FULL_ROLES=0
FORCE_KEY=0

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "'$1' not found. $2"
}

usage() {
  sed -n '2,14p' "$0"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push-secrets) PUSH_SECRETS=1 ;;
    --full) FULL_ROLES=1 ;;
    --force-key) FORCE_KEY=1 ;;
    -h|--help) usage ;;
    *) die "Unknown option: $1 (try --help)" ;;
  esac
  shift
done

require_cmd gcloud "Install: https://cloud.google.com/sdk/docs/install"

resolve_gcp_project() {
  if [[ -n "${GCP_PROJECT:-}" ]]; then
    return
  fi
  GCP_PROJECT="$(gcloud config get-value project 2>/dev/null || true)"
  if [[ -z "$GCP_PROJECT" || "$GCP_PROJECT" == "(unset)" ]]; then
    die "Set GCP_PROJECT or run: gcloud config set project YOUR_PROJECT_ID"
  fi
}

resolve_github_repo() {
  if [[ -n "${GITHUB_REPO:-}" ]]; then
    return
  fi
  if command -v gh >/dev/null 2>&1; then
    GITHUB_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  fi
  if [[ -z "${GITHUB_REPO:-}" ]] && git -C "$REPO_ROOT" remote get-url origin &>/dev/null; then
    GITHUB_REPO="$(git -C "$REPO_ROOT" remote get-url origin | sed -E 's#.*github.com[:/](.+/.+?)(\.git)?$#\1#')"
  fi
  GITHUB_REPO="${GITHUB_REPO:-dakaii/fantastic-spoon}"
}

resolve_gcp_project
resolve_github_repo

SA_EMAIL="${SA_ID}@${GCP_PROJECT}.iam.gserviceaccount.com"

log "Project:     ${GCP_PROJECT}"
log "GitHub repo: ${GITHUB_REPO}"
log "SA email:    ${SA_EMAIL}"
if [[ "$FULL_ROLES" -eq 1 ]]; then
  log "Roles mode:  full (bootstrap + terraform deploy)"
else
  log "Roles mode:  bootstrap (Compute Viewer only)"
fi

if ! gcloud auth print-access-token >/dev/null 2>&1; then
  die "Not logged in. Run: gcloud auth login"
fi

if gcloud iam service-accounts describe "$SA_EMAIL" --project="$GCP_PROJECT" &>/dev/null; then
  log "Service account already exists: ${SA_EMAIL}"
else
  log "Creating service account: ${SA_ID}"
  gcloud iam service-accounts create "$SA_ID" \
    --project="$GCP_PROJECT" \
    --display-name="$SA_NAME"
fi

bind_role() {
  local role="$1"
  log "Granting ${role}"
  gcloud projects add-iam-policy-binding "$GCP_PROJECT" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
}

bind_role "roles/compute.viewer"

if [[ "$FULL_ROLES" -eq 1 ]]; then
  bind_role "roles/compute.admin"
  bind_role "roles/storage.admin"
  bind_role "roles/iam.serviceAccountUser"
fi

mkdir -p "$KEY_DIR"
chmod 700 "$KEY_DIR"

if [[ -f "$KEY_FILE" && "$FORCE_KEY" -eq 0 ]]; then
  log "Using existing key file: ${KEY_FILE} (--force-key to create a new one)"
else
  log "Creating service account key: ${KEY_FILE}"
  gcloud iam service-accounts keys create "$KEY_FILE" \
    --project="$GCP_PROJECT" \
    --iam-account="$SA_EMAIL"
  chmod 600 "$KEY_FILE"
fi

if [[ ! -f "$SSH_KEY" ]]; then
  die "SSH private key not found at ${SSH_KEY}. Set SSH_PRIVATE_KEY_PATH or create ~/.ssh/id_ed25519"
fi

echo ""
log "GCP service account ready"
echo ""
echo "Local key (gitignored): ${KEY_FILE}"
echo ""

if [[ "$PUSH_SECRETS" -eq 1 ]]; then
  require_cmd gh "Install gh and run: gh auth login"
  if ! gh auth status >/dev/null 2>&1; then
    die "gh not authenticated. Run: gh auth login"
  fi

  log "Pushing GitHub secrets to ${GITHUB_REPO}"
  gh secret set GCP_PROJECT -b "$GCP_PROJECT" -R "$GITHUB_REPO"
  gh secret set GCP_SA_KEY < "$KEY_FILE" -R "$GITHUB_REPO"
  gh secret set SSH_PRIVATE_KEY < "$SSH_KEY" -R "$GITHUB_REPO"

  if [[ -f "${SSH_KEY}.pub" ]]; then
    gh secret set SSH_PUBLIC_KEY < "${SSH_KEY}.pub" -R "$GITHUB_REPO"
  fi

  log "GitHub secrets updated: GCP_PROJECT, GCP_SA_KEY, SSH_PRIVATE_KEY"
else
  echo "Push secrets manually (or re-run with --push-secrets):"
  echo ""
  echo "  gh secret set GCP_PROJECT -b \"${GCP_PROJECT}\" -R ${GITHUB_REPO}"
  echo "  gh secret set GCP_SA_KEY    < \"${KEY_FILE}\" -R ${GITHUB_REPO}"
  echo "  gh secret set SSH_PRIVATE_KEY < \"${SSH_KEY}\" -R ${GITHUB_REPO}"
  echo ""
fi

echo "========================================"
echo " One more step: SSH firewall"
echo "========================================"
echo ""
echo "GitHub runners need SSH access to your VMs. Easiest for dev:"
echo ""
echo "  1. Edit primary-cluster-gcp/terraform.tfvars"
echo "       admin_cidr = \"0.0.0.0/0\""
echo "  2. cd primary-cluster-gcp && terraform apply"
echo ""
echo "Then run bootstrap from GitHub:"
echo "  Actions → GCP Bootstrap → Run workflow → cluster: primary"
echo ""
echo "See docs/GITHUB-ACTIONS-SETUP.md for details."
