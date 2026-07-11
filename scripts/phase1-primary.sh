#!/usr/bin/env bash
# phase1-primary.sh — Provision + bootstrap primary (uses config/clusters.yaml)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -f "${REPO_ROOT}/config/clusters.yaml" ]]; then
  cp "${REPO_ROOT}/config/clusters.example.yaml" "${REPO_ROOT}/config/clusters.yaml"
  echo "Created config/clusters.yaml — edit if switching to on-prem or libvirt"
fi

"${REPO_ROOT}/scripts/provision.sh" primary
"${REPO_ROOT}/scripts/bootstrap-cluster.sh" primary
