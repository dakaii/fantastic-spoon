#!/usr/bin/env bash
# vpn-peer-list.sh — List WireGuard client peers for a city
#
# Usage:
#   ./scripts/vpn-peer-list.sh [city]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REPO_ROOT
# shellcheck source=vpn-peers-lib.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/vpn-peers-lib.sh"

CITY="${1:-}"
if [[ -z "$CITY" ]]; then
  if [[ -d "${REPO_ROOT}/vpn-gateways-gcp" ]]; then
    CITY="$(terraform -chdir="${REPO_ROOT}/vpn-gateways-gcp" output -raw vpn_city 2>/dev/null || echo us)"
  else
    CITY=us
  fi
fi

vpn_peers_migrate_legacy "$CITY"
PEERS="$(vpn_peers_dir "$CITY")"

if [[ "$(vpn_peers_count "$CITY")" -eq 0 ]]; then
  echo "No peers in ${PEERS}/ — run ./scripts/vpn-bootstrap.sh or vpn-peer-add.sh"
  exit 0
fi

printf '%-16s %-18s %s\n' "NAME" "ADDRESS" "PUBLIC_KEY"
printf '%-16s %-18s %s\n' "----" "-------" "----------"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  addr="$(cat "${PEERS}/${name}.address")"
  pub="$(cat "${PEERS}/${name}.publickey")"
  printf '%-16s %-18s %s\n' "$name" "$addr" "$pub"
done < <(vpn_peers_list_names "$CITY")
