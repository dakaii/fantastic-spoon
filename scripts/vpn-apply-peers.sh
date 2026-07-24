#!/usr/bin/env bash
# vpn-apply-peers.sh — Push all local peers to the WireGuard gateway via Ansible
#
# Usage:
#   ./scripts/vpn-apply-peers.sh [city]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REPO_ROOT
TF_DIR="${REPO_ROOT}/vpn-gateways-gcp"
# shellcheck source=vpn-peers-lib.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/vpn-peers-lib.sh"
# shellcheck source=vpn-city-lib.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/vpn-city-lib.sh"

CITY="${1:-}"
if [[ -z "$CITY" ]]; then
  CITY="$(terraform -chdir="$TF_DIR" output -raw vpn_city 2>/dev/null || echo us)"
fi
INV_OUT="$(vpn_city_inventory_path "$CITY")"

vpn_peers_migrate_legacy "$CITY"

command -v terraform >/dev/null 2>&1 || {
  echo "ERROR: terraform not found" >&2
  exit 1
}
command -v ansible-playbook >/dev/null 2>&1 || {
  echo "ERROR: ansible-playbook not found" >&2
  exit 1
}

echo "==> Refreshing inventory from Terraform → ${INV_OUT}"
mkdir -p "$(dirname "$INV_OUT")"
terraform -chdir="$TF_DIR" output -raw ansible_inventory >"$INV_OUT"
ln -sfn "$(basename "$INV_OUT")" "${REPO_ROOT}/ansible/inventory/vpn-hosts.yml"
[[ -s "$INV_OUT" ]] || {
  echo "ERROR: empty inventory — apply vpn-gateways-gcp first (VPN_CITY=${CITY})" >&2
  exit 1
}

PORT="$(vpn_peers_tf_port)"
VARS_FILE="$(mktemp)"
trap 'rm -f "$VARS_FILE"' EXIT
vpn_peers_ansible_vars "$CITY" >"$VARS_FILE"

echo "==> Applying $(vpn_peers_count "$CITY") peer(s) to gateway (city=${CITY})"
(
  cd "${REPO_ROOT}/ansible"
  ansible-playbook -i "inventory/vpn-hosts-${CITY}.yml" playbooks/vpn-gateway.yml \
    -e "@${VARS_FILE}" \
    -e "wireguard_port=${PORT}" \
    -e "vpn_city=${CITY}"
)

echo "==> Gateway updated. List peers: ./scripts/vpn-peer-list.sh ${CITY}"
