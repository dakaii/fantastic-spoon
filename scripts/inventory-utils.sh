#!/usr/bin/env bash
# inventory-utils.sh — Shared helpers for Ansible inventory files.
# Supports standard YAML (cluster_name:) and Terraform yamlencode ("cluster_name":).

inventory_has_field() {
  local field="$1"
  local file="$2"
  grep -qE "(^|[[:space:]])\"${field}\"[[:space:]]*:|(^|[[:space:]])${field}[[:space:]]*:" "$file"
}

inventory_ansible_hosts() {
  local file="$1"
  grep -E 'ansible_host' "$file" \
    | sed -E 's/^[[:space:]]*("ansible_host"|ansible_host)[[:space:]]*:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\2/'
}

inventory_first_control_plane_ip() {
  local file="$1"
  grep -A20 -E '"k3s_server"|k3s_server:' "$file" \
    | grep -E 'ansible_host' \
    | head -1 \
    | sed -E 's/^[[:space:]]*("ansible_host"|ansible_host)[[:space:]]*:[[:space:]]*"?([^"[:space:]]+)"?[[:space:]]*$/\2/'
}

inventory_ansible_host_count() {
  local file="$1"
  local count=0
  local host
  while IFS= read -r host; do
    [[ -n "$host" ]] && count=$((count + 1))
  done < <(inventory_ansible_hosts "$file")
  echo "$count"
}

inventory_read_ansible_hosts() {
  # Populates the array named by $1 (Bash 3.2 compatible; no mapfile).
  local array_name="$1"
  local file="$2"
  local host

  eval "${array_name}=()"
  while IFS= read -r host; do
    if [[ -n "$host" ]]; then
      eval "${array_name}+=(\"\${host}\")"
    fi
  done < <(inventory_ansible_hosts "$file")
}
