#!/usr/bin/env bash
# gcp-vpn-ci.sh — WireGuard VPN city gateway from GitHub Actions
#
# Requires env: GCP_PROJECT, SSH_PUBLIC_KEY, ADMIN_CIDR
# Optional: VPN_CITY (default us)
# Uploads client .conf as a workflow artifact from the caller.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

export SKIP_AUTH=1
export FORCE_TFVARS="${FORCE_TFVARS:-1}"
export VPN_CITY="${VPN_CITY:-us}"

: "${GCP_PROJECT:?Set GCP_PROJECT}"
: "${SSH_PUBLIC_KEY:?Set SSH_PUBLIC_KEY}"
: "${ADMIN_CIDR:?Set ADMIN_CIDR}"

log() { echo "==> $*"; }

command -v wg >/dev/null 2>&1 || {
  echo "ERROR: wireguard-tools (wg) required on the runner" >&2
  exit 1
}

gcloud config set project "$GCP_PROJECT"

log "Pulling Terraform state from GCS (if any)"
"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" pull

# Discover primary NAT CIDRs before writing tfvars (so :9100 is not world-open via admin_cidr)
if [[ -z "${VPN_METRICS_CIDRS:-}" ]]; then
  _cidrs=()
  while IFS= read -r _c; do
    [[ -n "$_c" ]] && _cidrs+=("$_c")
  done < <("${REPO_ROOT}/scripts/vpn-discover-metrics-cidrs.sh" || true)
  if [[ ${#_cidrs[@]} -gt 0 ]]; then
    VPN_METRICS_CIDRS="$(IFS=,; echo "${_cidrs[*]}")"
    export VPN_METRICS_CIDRS
    log "VPN_METRICS_CIDRS=${VPN_METRICS_CIDRS}"
  elif [[ "${ADMIN_CIDR}" == "0.0.0.0/0" ]]; then
    echo "ERROR: could not discover primary NAT IPs and ADMIN_CIDR is 0.0.0.0/0." >&2
    echo "  Metrics :9100 would be world-reachable. Deploy/bootstrap primary first, or set:" >&2
    echo "  VPN_METRICS_CIDRS=34.x.x.x/32,34.y.y.y/32" >&2
    exit 1
  else
    log "WARN: no primary CIDRs discovered — vpn_metrics_cidrs will default to admin_cidr=${ADMIN_CIDR}"
  fi
fi

log "Writing terraform.tfvars"
"${REPO_ROOT}/scripts/gcp-deploy.sh" init

log "VPN provision + WireGuard bootstrap (+ monitoring wire)"
export SKIP_AUTH=1
"${REPO_ROOT}/scripts/gcp-deploy.sh" vpn

log "Pushing Terraform state to GCS (includes any vpn_metrics_cidrs apply)"
"${REPO_ROOT}/scripts/gcp-tfstate-sync.sh" push

CITY="$VPN_CITY"
CONF="${REPO_ROOT}/vpn-clients/${CITY}/laptop-${CITY}.conf"
if [[ -f "$CONF" ]]; then
  mkdir -p "${REPO_ROOT}/tmp/vpn-artifact"
  cp "$CONF" "${REPO_ROOT}/tmp/vpn-artifact/"
  # Also pack any extra peer configs generated in CI (usually just laptop)
  shopt -s nullglob
  for extra in "${REPO_ROOT}/vpn-clients/${CITY}"/*-"${CITY}".conf; do
    cp "$extra" "${REPO_ROOT}/tmp/vpn-artifact/" 2>/dev/null || true
  done
  shopt -u nullglob
  # Public endpoint only — do not print private keys
  log "Client config ready for artifact upload: tmp/vpn-artifact/$(basename "$CONF")"
  terraform -chdir="${REPO_ROOT}/vpn-gateways-gcp" output -raw vpn_public_ip || true
else
  echo "ERROR: expected client config at ${CONF}" >&2
  exit 1
fi

log "VPN CI complete — download the workflow artifact and import into WireGuard"
