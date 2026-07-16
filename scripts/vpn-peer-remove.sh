#!/usr/bin/env bash
# vpn-peer-remove.sh — Remove a WireGuard client peer
#
# Usage:
#   ./scripts/vpn-peer-remove.sh <city> <client-name> [--apply]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REPO_ROOT
# shellcheck source=vpn-peers-lib.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/vpn-peers-lib.sh"

CITY="${1:?Usage: vpn-peer-remove.sh <city> <client-name> [--apply]}"
NAME="${2:?Usage: vpn-peer-remove.sh <city> <client-name> [--apply]}"
APPLY=0
[[ "${3:-}" == "--apply" ]] && APPLY=1

PEERS="$(vpn_peers_dir "$CITY")"
PRIV="${PEERS}/${NAME}.privatekey"

[[ -f "$PRIV" ]] || {
  echo "ERROR: peer '${NAME}' not found under ${PEERS}/" >&2
  exit 1
}

if [[ "$(vpn_peers_count "$CITY")" -le 1 ]]; then
  echo "ERROR: refusing to remove the last peer — add another first or destroy the city" >&2
  exit 1
fi

rm -f \
  "${PEERS}/${NAME}.privatekey" \
  "${PEERS}/${NAME}.publickey" \
  "${PEERS}/${NAME}.address" \
  "$(vpn_peers_city_dir "$CITY")/${NAME}-${CITY}.conf"

echo "==> Removed peer ${NAME}"

if [[ "$APPLY" -eq 1 ]]; then
  "${REPO_ROOT}/scripts/vpn-apply-peers.sh" "$CITY"
else
  echo "==> Gateway still has old peer until you run:"
  echo "    ./scripts/vpn-apply-peers.sh ${CITY}"
fi
