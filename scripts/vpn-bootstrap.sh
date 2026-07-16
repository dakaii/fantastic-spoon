#!/usr/bin/env bash
# vpn-bootstrap.sh — Additive: keys + inventory + Ansible WG (multi-peer) + laptop client
#
# Prerequisites:
#   terraform -chdir=vpn-gateways-gcp apply
#   ssh access as ubuntu to the gateway
#
# Does NOT touch primary/standby clusters.
#
# Default: creates the first peer "laptop". Add more with:
#   ./scripts/vpn-peer-add.sh <city> phone --apply
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REPO_ROOT
TF_DIR="${REPO_ROOT}/vpn-gateways-gcp"
INV_OUT="${REPO_ROOT}/ansible/inventory/vpn-hosts.yml"
# shellcheck source=vpn-peers-lib.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/vpn-peers-lib.sh"

log() { echo "==> $*"; }

vpn_peers_require_wg

command -v terraform >/dev/null 2>&1 || {
  echo "ERROR: terraform not found" >&2
  exit 1
}

[[ -f "${TF_DIR}/terraform.tfvars" ]] || {
  echo "ERROR: missing ${TF_DIR}/terraform.tfvars — copy from terraform.tfvars.example" >&2
  exit 1
}

log "Reading VPN Terraform outputs"
CITY="$(terraform -chdir="$TF_DIR" output -raw vpn_city)"
ENDPOINT="$(terraform -chdir="$TF_DIR" output -raw vpn_public_ip)"
PORT="$(terraform -chdir="$TF_DIR" output -raw wireguard_port)"
DIR="$(vpn_peers_city_dir "$CITY")"
PEERS="$(vpn_peers_dir "$CITY")"

vpn_peers_ensure_dirs "$CITY"
vpn_peers_migrate_legacy "$CITY"

vpn_peers_gen_keypair "${DIR}/server.privatekey" "${DIR}/server.publickey"

# First consumer device
if [[ ! -f "${PEERS}/laptop.privatekey" ]]; then
  log "Creating first peer: laptop"
  vpn_peers_gen_keypair "${PEERS}/laptop.privatekey" "${PEERS}/laptop.publickey"
  echo "10.66.0.2/32" >"${PEERS}/laptop.address"
  chmod 600 "${PEERS}/laptop.address"
else
  log "Reusing existing peer: laptop"
fi

# Keep legacy filenames in sync for older docs/scripts
if [[ ! -f "${DIR}/client.privatekey" ]]; then
  cp "${PEERS}/laptop.privatekey" "${DIR}/client.privatekey"
  cp "${PEERS}/laptop.publickey" "${DIR}/client.publickey"
  chmod 600 "${DIR}/client.privatekey" "${DIR}/client.publickey"
fi

log "Writing ${INV_OUT}"
terraform -chdir="$TF_DIR" output -raw ansible_inventory >"$INV_OUT"
[[ -s "$INV_OUT" ]] || {
  echo "ERROR: empty inventory from terraform output" >&2
  exit 1
}

log "Configuring WireGuard on gateway (all peers)"
"${REPO_ROOT}/scripts/vpn-apply-peers.sh" "$CITY"

log "Writing laptop client config"
VPN_ENDPOINT="$ENDPOINT" WIREGUARD_PORT="$PORT" \
  "${REPO_ROOT}/scripts/generate-wg-client-config.sh" "$CITY" laptop

cat <<EOF

VPN city '${CITY}' is ready (multi-peer enabled).

  Laptop config: ${DIR}/laptop-${CITY}.conf
  Endpoint:      ${ENDPOINT}:${PORT}
  Peers:         ./scripts/vpn-peer-list.sh ${CITY}

Add another device (phone / tablet / friend):
  ./scripts/vpn-peer-add.sh ${CITY} phone --apply

Import the .conf into the official WireGuard app, activate the tunnel, then:
  curl -4 ifconfig.me    # should show ${ENDPOINT} when full tunnel is on

Metrics:
  curl -s http://${ENDPOINT}:9100/metrics | grep wireguard_
  ./scripts/vpn-prometheus-scrape-snippet.sh

See docs/CONSUMER-VPN.md and docs/VPN-RUNBOOK.md
EOF
