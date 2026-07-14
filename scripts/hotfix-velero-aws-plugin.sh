#!/usr/bin/env bash
# hotfix-velero-aws-plugin.sh — Force Velero AWS plugin onto a live primary cluster
#
# Usage:
#   GCP_PROJECT=hybrid-k8s-dev ./scripts/hotfix-velero-aws-plugin.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/inventory-utils.sh
source "${REPO_ROOT}/scripts/inventory-utils.sh"

PLUGIN_IMAGE="${VELERO_AWS_PLUGIN_IMAGE:-velero/velero-plugin-for-aws:v1.14.0}"
INVENTORY="${REPO_ROOT}/ansible/inventory/primary-hosts.yml"

if [[ -n "${GCP_PROJECT:-}" ]] && command -v gcloud >/dev/null 2>&1; then
  GCP_PROJECT="${GCP_PROJECT}" "${REPO_ROOT}/scripts/generate-gcp-inventory.sh" primary
fi

CP="${1:-}"
if [[ -z "$CP" ]]; then
  [[ -f "$INVENTORY" ]] || {
    echo "ERROR: Missing ${INVENTORY}; pass CP IP as arg or set GCP_PROJECT" >&2
    exit 1
  }
  CP="$(inventory_first_control_plane_ip "$INVENTORY")"
fi
[[ -n "$CP" ]] || {
  echo "ERROR: Could not resolve primary control plane IP" >&2
  exit 1
}

echo "==> Patching Velero on ${CP} with ${PLUGIN_IMAGE}"
ssh -o StrictHostKeyChecking=no "ubuntu@${CP}" bash -s -- "$PLUGIN_IMAGE" <<'EOF'
set -euo pipefail
PLUGIN_IMAGE="$1"
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm repo add vmware-tanzu https://vmware-tanzu.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update vmware-tanzu >/dev/null
helm upgrade velero vmware-tanzu/velero -n velero --reuse-values \
  --set-json "initContainers=[{\"name\":\"velero-plugin-for-aws\",\"image\":\"${PLUGIN_IMAGE}\",\"imagePullPolicy\":\"IfNotPresent\",\"volumeMounts\":[{\"mountPath\":\"/target\",\"name\":\"plugins\"}]}]" \
  --wait --timeout 10m
kubectl -n velero rollout status deploy/velero --timeout=180s
echo "initContainers: $(kubectl -n velero get deploy velero -o jsonpath='{.spec.template.spec.initContainers[*].name}')"
for i in $(seq 1 36); do
  phase="$(kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  echo "BSL phase=${phase:-unknown}"
  [[ "$phase" == "Available" ]] && exit 0
  sleep 5
done
kubectl -n velero describe backupstoragelocation default | tail -40
exit 1
EOF
