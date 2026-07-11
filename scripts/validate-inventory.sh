#!/usr/bin/env bash
# validate-inventory.sh — Check inventory matches the provider contract
set -euo pipefail

INVENTORY="${1:?Usage: validate-inventory.sh <inventory-file>}"

if [[ ! -f "$INVENTORY" ]]; then
  echo "ERROR: File not found: $INVENTORY"
  exit 1
fi

errors=0

check() {
  if ! grep -q "$1" "$INVENTORY"; then
    echo "ERROR: Missing required field: $1"
    errors=$((errors + 1))
  fi
}

check "cluster_name:"
check "cluster_profile:"
check "provisioner:"
check "k3s_server:"
check "k3s_agent:"
check "ansible_host:"

if grep -q "PENDING_BOOT" "$INVENTORY"; then
  echo "WARN: Inventory contains PENDING_BOOT — update ansible_host IPs before bootstrap"
fi

if [[ $errors -gt 0 ]]; then
  echo "Validation failed with $errors error(s)"
  exit 1
fi

echo "OK: $INVENTORY matches provider contract"
hosts=$(grep -c "ansible_host:" "$INVENTORY" || true)
echo "   $hosts node(s) defined"
