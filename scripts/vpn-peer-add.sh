#!/usr/bin/env bash
# vpn-peer-add.sh — Add a WireGuard client peer (multi-device consumer VPN)
#
# Usage:
#   ./scripts/vpn-peer-add.sh <city> <client-name> [--apply]
#
# Example:
#   ./scripts/vpn-peer-add.sh us phone --apply
#
# Creates keys + address under vpn-clients/<city>/peers/, writes .conf,
# and optionally pushes all peers to the gateway via Ansible.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REPO_ROOT
# shellcheck source=vpn-peers-lib.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/vpn-peers-lib.sh"

CITY="${1:?Usage: vpn-peer-add.sh <city> <client-name> [--apply]}"
NAME="${2:?Usage: vpn-peer-add.sh <city> <client-name> [--apply]}"
APPLY=0
[[ "${3:-}" == "--apply" ]] && APPLY=1

if [[ ! "$NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
  echo "ERROR: client name must be alphanumeric (plus _ -)" >&2
  exit 1
fi

vpn_peers_require_wg
vpn_peers_ensure_dirs "$CITY"
vpn_peers_migrate_legacy "$CITY"

PEERS="$(vpn_peers_dir "$CITY")"
PRIV="${PEERS}/${NAME}.privatekey"
PUB="${PEERS}/${NAME}.publickey"
ADDR_FILE="${PEERS}/${NAME}.address"

if [[ -f "$PRIV" ]]; then
  echo "ERROR: peer '${NAME}' already exists (${PRIV})" >&2
  echo "  Remove with: ./scripts/vpn-peer-remove.sh ${CITY} ${NAME}" >&2
  exit 1
fi

DIR="$(vpn_peers_city_dir "$CITY")"
[[ -f "${DIR}/server.publickey" ]] || {
  echo "ERROR: missing server keys — run ./scripts/vpn-bootstrap.sh first" >&2
  exit 1
}

ADDR="$(vpn_peers_next_address "$CITY")"
vpn_peers_gen_keypair "$PRIV" "$PUB"
echo "$ADDR" >"$ADDR_FILE"
chmod 600 "$ADDR_FILE"

echo "==> Added peer ${NAME} address=${ADDR}"

ENDPOINT="$(vpn_peers_tf_endpoint)"
PORT="$(vpn_peers_tf_port)"
if [[ -n "$ENDPOINT" ]]; then
  VPN_ENDPOINT="$ENDPOINT" WIREGUARD_PORT="$PORT" \
    "${REPO_ROOT}/scripts/generate-wg-client-config.sh" "$CITY" "$NAME"
else
  echo "==> Skipping .conf (no VPN_ENDPOINT / terraform output yet)"
fi

if [[ "$APPLY" -eq 1 ]]; then
  "${REPO_ROOT}/scripts/vpn-apply-peers.sh" "$CITY"
else
  echo "==> Gateway not updated. Apply with:"
  echo "    ./scripts/vpn-apply-peers.sh ${CITY}"
  echo "  or re-run: ./scripts/vpn-peer-add.sh ${CITY} ${NAME} --apply"
fi
