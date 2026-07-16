#!/usr/bin/env bash
# vpn-bootstrap.sh — Additive V1: keys + inventory + Ansible WG configure + client config
#
# Prerequisites:
#   terraform -chdir=vpn-gateways-gcp apply
#   ssh access as ubuntu to the gateway
#
# Does NOT touch primary/standby clusters.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="${REPO_ROOT}/vpn-gateways-gcp"
INV_OUT="${REPO_ROOT}/ansible/inventory/vpn-hosts.yml"
CLIENTS_ROOT="${REPO_ROOT}/vpn-clients"

log() { echo "==> $*"; }

command -v wg >/dev/null 2>&1 || {
  echo "ERROR: wireguard-tools (wg) required on this machine to generate keys" >&2
  echo "  macOS: brew install wireguard-tools" >&2
  echo "  Debian/Ubuntu: sudo apt-get install -y wireguard-tools" >&2
  exit 1
}

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
DIR="${CLIENTS_ROOT}/${CITY}"
mkdir -p "$DIR"
chmod 700 "$CLIENTS_ROOT" "$DIR" 2>/dev/null || true

gen_keypair() {
  local priv="$1" pub="$2"
  if [[ ! -f "$priv" ]]; then
    umask 077
    wg genkey | tee "$priv" | wg pubkey >"$pub"
    chmod 600 "$priv" "$pub"
    log "Generated $(basename "$priv")"
  else
    log "Reusing existing $(basename "$priv")"
  fi
}

gen_keypair "${DIR}/server.privatekey" "${DIR}/server.publickey"
gen_keypair "${DIR}/client.privatekey" "${DIR}/client.publickey"

log "Writing ${INV_OUT}"
terraform -chdir="$TF_DIR" output -raw ansible_inventory >"$INV_OUT"

# terraform yamlencode may quote oddly; ensure file is non-empty
[[ -s "$INV_OUT" ]] || {
  echo "ERROR: empty inventory from terraform output" >&2
  exit 1
}

log "Configuring WireGuard on gateway via Ansible"
(
  cd "${REPO_ROOT}/ansible"
  ansible-playbook -i inventory/vpn-hosts.yml playbooks/vpn-gateway.yml \
    -e "wg_server_private_key=$(cat "${DIR}/server.privatekey")" \
    -e "wg_server_public_key=$(cat "${DIR}/server.publickey")" \
    -e "wg_client_public_key=$(cat "${DIR}/client.publickey")" \
    -e "wireguard_port=${PORT}" \
    -e "vpn_city=${CITY}" \
    -e "wg_client_name=laptop"
)

log "Writing client config"
VPN_ENDPOINT="$ENDPOINT" WIREGUARD_PORT="$PORT" \
  "${REPO_ROOT}/scripts/generate-wg-client-config.sh" "$CITY" laptop

cat <<EOF

VPN city '${CITY}' is ready.

  Client config: ${DIR}/laptop-${CITY}.conf
  Endpoint:      ${ENDPOINT}:${PORT}

Import the .conf into the official WireGuard app, activate the tunnel, then:
  curl -4 ifconfig.me    # should show ${ENDPOINT} when full tunnel is on

Metrics (after Ansible exporters):
  curl -s http://${ENDPOINT}:9100/metrics | grep wireguard_
  ./scripts/vpn-prometheus-scrape-snippet.sh

See docs/CONSUMER-VPN.md and docs/VPN-RUNBOOK.md
EOF
