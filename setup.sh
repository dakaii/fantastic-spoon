#!/usr/bin/env bash
# setup.sh — one-command GCP quickstart (Path 2)
#
#   ./setup.sh                  # full deploy: login → config → infra → Linkding
#   ./setup.sh destroy          # tear down GCP resources (save $)
#   GCP_PROJECT=my-project ./setup.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO_ROOT"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

ensure_ssh_key() {
  if [[ -f "${HOME}/.ssh/id_ed25519.pub" || -f "${HOME}/.ssh/id_rsa.pub" ]]; then
    return
  fi
  log "Creating SSH key (~/.ssh/id_ed25519)"
  ssh-keygen -t ed25519 -f "${HOME}/.ssh/id_ed25519" -N ""
}

check_tools() {
  local missing=()
  for cmd in gcloud terraform ansible-playbook kubectl jq curl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing tools: ${missing[*]}. Install gcloud, terraform, ansible, kubectl, jq — then re-run ./setup.sh"
  fi
}

cmd_destroy() {
  : "${GCP_PROJECT:?Set GCP_PROJECT (e.g. GCP_PROJECT=hybrid-k8s-dev ./setup.sh destroy)}"
  chmod +x scripts/*.sh 2>/dev/null || true
  log "Delegating to scripts/gcp-teardown.sh (ADC check + state push + destroy)"
  exec "${REPO_ROOT}/scripts/gcp-teardown.sh"
}

main() {
  case "${1:-}" in
    destroy)
      cmd_destroy
      exit 0
      ;;
    -h|--help|help)
      cat <<EOF
Usage: ./setup.sh [destroy]

  ./setup.sh            Deploy everything on GCP (k3s + standby + Linkding)
  ./setup.sh destroy    Tear down via scripts/gcp-teardown.sh (needs GCP_PROJECT)

Optional: GCP_PROJECT=your-project-id ./setup.sh
EOF
      exit 0
      ;;
  esac

  ensure_ssh_key
  check_tools
  chmod +x scripts/*.sh 2>/dev/null || true

  log "Starting GCP deploy (20–40 min). Billing must be enabled on your project."
  exec "${REPO_ROOT}/scripts/gcp-deploy.sh" all
}

main "$@"
