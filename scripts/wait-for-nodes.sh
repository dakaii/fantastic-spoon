#!/usr/bin/env bash
# wait-for-nodes.sh — Wait until EC2 nodes accept SSH connections
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=inventory-utils.sh
source "${SCRIPT_DIR}/inventory-utils.sh"

INVENTORY="${1:?Usage: wait-for-nodes.sh <inventory-file>}"
TIMEOUT="${2:-300}"
INTERVAL=10

if [[ ! -f "$INVENTORY" ]]; then
  echo "Inventory file not found: $INVENTORY"
  exit 1
fi

mapfile -t HOSTS < <(inventory_ansible_hosts "$INVENTORY")

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo "No ansible_host entries found in $INVENTORY"
  exit 1
fi

echo "Waiting for ${#HOSTS[@]} nodes (timeout: ${TIMEOUT}s)..."

deadline=$((SECONDS + TIMEOUT))
ready=0

while [[ $SECONDS -lt $deadline ]]; do
  ready=0
  for host in "${HOSTS[@]}"; do
    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes \
        "ubuntu@${host}" "echo ok" &>/dev/null; then
      ready=$((ready + 1))
      echo "  ✓ ${host}"
    else
      echo "  · ${host} (not ready)"
    fi
  done

  if [[ $ready -eq ${#HOSTS[@]} ]]; then
    echo "All nodes ready."
    exit 0
  fi

  sleep "$INTERVAL"
done

echo "Timeout: only ${ready}/${#HOSTS[@]} nodes ready."
exit 1
