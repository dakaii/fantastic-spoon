#!/usr/bin/env bash
# phase2-standby.sh — Provision + bootstrap standby (uses config/clusters.yaml)
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -f "${REPO_ROOT}/config/clusters.yaml" ]]; then
  cp "${REPO_ROOT}/config/clusters.example.yaml" "${REPO_ROOT}/config/clusters.yaml"
fi

"${REPO_ROOT}/scripts/provision.sh" standby
"${REPO_ROOT}/scripts/bootstrap-cluster.sh" standby

echo ""
echo "Standby LB IP: terraform -chdir=cloud-services-gcp output standby_lb_ip"
echo "Next: register standby in primary Argo CD (gitops/argocd/clusters/cloud-standby.yaml)"
