#!/usr/bin/env bash
# vpn-discover-metrics-cidrs.sh — Primary node NAT CIDRs for VPN :9100 scrapes
#
# Prints one CIDR per line (e.g. 34.1.2.3/32). Sources (first that works):
#   1. terraform output primary_public_ips (primary-cluster-gcp)
#   2. gcloud compute instances with label cluster=primary
#
# Usage:
#   ./scripts/vpn-discover-metrics-cidrs.sh
#   VPN_METRICS_CIDRS=$(./scripts/vpn-discover-metrics-cidrs.sh | paste -sd, -)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRIMARY_TF="${REPO_ROOT}/primary-cluster-gcp"

emit_from_json_map() {
  local json="$1"
  command -v jq >/dev/null 2>&1 || return 1
  [[ -n "$json" && "$json" != "null" ]] || return 1
  echo "$json" | jq -r 'to_entries[] | .value' 2>/dev/null | while read -r ip; do
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "${ip}/32"
  done
}

from_terraform() {
  local json
  [[ -d "$PRIMARY_TF" ]] || return 1
  json="$(terraform -chdir="$PRIMARY_TF" output -json primary_public_ips 2>/dev/null || true)"
  emit_from_json_map "$json"
}

from_gcloud() {
  local project="${GCP_PROJECT:-}"
  [[ -n "$project" ]] || project="$(gcloud config get-value project 2>/dev/null || true)"
  [[ -n "$project" && "$project" != "(unset)" ]] || return 1
  command -v gcloud >/dev/null 2>&1 || return 1
  gcloud compute instances list --project="$project" \
    --filter="labels.cluster=primary AND status=RUNNING" \
    --format="get(networkInterfaces[0].accessConfigs[0].natIP)" 2>/dev/null \
    | while read -r ip; do
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "${ip}/32"
      done
}

CIDRS="$(from_terraform || true)"
if [[ -z "${CIDRS//[$'\n']/}" ]]; then
  CIDRS="$(from_gcloud || true)"
fi

# Deduplicate
if [[ -n "${CIDRS//[$'\n']/}" ]]; then
  echo "$CIDRS" | awk 'NF && !seen[$0]++'
  exit 0
fi

echo "WARNING: no primary public IPs found — set VPN_METRICS_CIDRS or admin_cidr carefully" >&2
exit 1
