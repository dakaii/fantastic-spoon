#!/usr/bin/env bash
# failover-gcp.sh — GCP Phase 4 operator helpers (manual app activation + notes)
#
# Cloud DNS cutover is handled by shared-services-gcp health checks.
# Velero/Argo inside Cloud Workflows are stubs — this script covers Level C.
#
# Usage:
#   STANDBY_KUBECONFIG=~/.kube/hybrid-standby.yaml ./scripts/failover-gcp.sh activate-apps
#   ./scripts/failover-gcp.sh failback-notes
#   ./scripts/failover-gcp.sh status
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="${1:-help}"

log() { echo "==> $*"; }

status() {
  if [[ -d "${REPO_ROOT}/shared-services-gcp" ]]; then
    if [[ -f "${REPO_ROOT}/shared-services-gcp/terraform.tfstate" ]] || \
       [[ -d "${REPO_ROOT}/shared-services-gcp/.terraform" ]]; then
      terraform -chdir="${REPO_ROOT}/shared-services-gcp" output 2>/dev/null || \
        log "No terraform outputs yet — apply shared-services-gcp first"
    fi
  fi
  log "Witness logs (if deployed):"
  echo "  gcloud functions logs read hybrid-k8s-witness --gen2 --region=\${GCP_REGION:-us-central1} --limit=20"
}

activate_apps() {
  local kube="${STANDBY_KUBECONFIG:-}"
  if [[ -z "$kube" || ! -f "$kube" ]]; then
    echo "ERROR: Set STANDBY_KUBECONFIG to a kubeconfig that reaches the standby cluster" >&2
    echo "  Example: copy from standby CP: ssh ubuntu@SB_IP 'sudo cat /etc/rancher/k3s/k3s.yaml'" >&2
    exit 1
  fi
  export KUBECONFIG="$kube"

  log "Scaling common standby apps (ignore NotFound)"
  kubectl -n linkding scale deploy/linkding --replicas=1 2>/dev/null || true
  kubectl -n demo scale deploy/demo-app --replicas=1 2>/dev/null || true

  if command -v velero >/dev/null 2>&1; then
    log "Latest Velero backups (run restore manually if needed):"
    velero backup get 2>/dev/null | head -20 || true
    echo "  velero restore create failover-\$(date +%s) --from-backup <NAME> --wait"
  else
    log "velero CLI not installed — skip restore hint"
  fi

  if kubectl get ns argocd >/dev/null 2>&1; then
    log "Argo CD applications:"
    kubectl get applications -n argocd 2>/dev/null || true
  fi

  log "Verify Traefik / services on standby, then confirm Cloud DNS points at standby_lb_ip"
}

failback_notes() {
  cat <<'EOF'
Failback (manual — no Workflow yet):

1. Confirm primary is healthy:
     curl -k https://PRIMARY_CP:6443/readyz
2. Reset witness state in Firestore document witness/health:
     consecutive_failures=0, failover_active=false
3. Wait for Cloud DNS primary health check to pass (TCP :443 on primary LB)
4. Scale down standby demo apps if desired:
     STANDBY_KUBECONFIG=... kubectl -n linkding scale deploy/linkding --replicas=0
5. Document the incident in docs/GCP-BOOTSTRAP-ISSUES.md if useful
EOF
}

help() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  status          Shared-services outputs + log hints
  activate-apps   Scale standby workloads (needs STANDBY_KUBECONFIG)
  failback-notes  Print manual failback steps
  help            This message

See docs/PHASE-4-RUNBOOK.md
EOF
}

case "$CMD" in
  status) status ;;
  activate-apps) activate_apps ;;
  failback-notes) failback_notes ;;
  help|-h|--help) help ;;
  *) echo "Unknown command: $CMD" >&2; help; exit 1 ;;
esac
