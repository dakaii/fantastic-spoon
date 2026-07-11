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
echo "Standby NLB: check cloud-services terraform output or inventory meta file"
echo "Next: register standby in primary Argo CD (gitops/argocd/clusters/cloud-standby.yaml)"
