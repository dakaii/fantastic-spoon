#!/usr/bin/env bash
# failover-gcp.sh — GCP Phase 4 Level C operator helpers (manual app activation)
#
# Honest boundary:
#   Level A — Cloud Function witness (automated probe)
#   Level B — Cloud DNS primary/backup (health-check cutover when configured)
#   Level C — Apps on standby: THIS SCRIPT (operator). Workflow Velero/Argo are stubs.
#
# Usage:
#   ./scripts/failover-gcp.sh status
#   ./scripts/failover-gcp.sh activate-apps --dry-run
#   STANDBY_KUBECONFIG=~/.kube/hybrid-standby.yaml ./scripts/failover-gcp.sh activate-apps
#   ./scripts/failover-gcp.sh failback-notes
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="${1:-help}"
shift || true
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
  esac
done

log() { echo "==> $*"; }

banner() {
  cat <<'EOF'
Phase 4 levels:
  A  Witness     — Cloud Function + Scheduler (automated)
  B  DNS         — Cloud DNS HC cutover (when domain configured)
  C  Apps        — OPERATOR: Velero restore + scale/sync (Workflow does NOT do this)

Cloud Workflow "FAILOVER" notify ≠ apps restored. Use activate-apps for Level C.
EOF
}

status() {
  banner
  echo ""
  if [[ -d "${REPO_ROOT}/shared-services-gcp" ]]; then
    if [[ -f "${REPO_ROOT}/shared-services-gcp/terraform.tfstate" ]] || \
       [[ -d "${REPO_ROOT}/shared-services-gcp/.terraform" ]]; then
      log "shared-services-gcp outputs:"
      terraform -chdir="${REPO_ROOT}/shared-services-gcp" output 2>/dev/null || \
        log "No terraform outputs yet — apply shared-services-gcp first"
    else
      log "shared-services-gcp not applied yet"
    fi
  fi
  echo ""
  log "Level A — witness logs (if deployed):"
  echo "  gcloud functions logs read hybrid-k8s-witness --gen2 --region=\${GCP_REGION:-us-central1} --limit=20"
  echo ""
  log "Level C — next steps when failing over:"
  echo "  1. Confirm DNS / standby LB (Level B) if you use a domain"
  echo "  2. STANDBY_KUBECONFIG=... $0 activate-apps [--dry-run]"
  echo "  3. $0 failback-notes  (after primary recovers)"
  echo ""
  log "Workflow stubs: shared-services-gcp/workflows/failover.yaml (notify only)"
}

run_or_print() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: $*"
  else
    # shellcheck disable=SC2068
    "$@"
  fi
}

activate_apps() {
  banner
  echo ""
  local kube="${STANDBY_KUBECONFIG:-}"
  if [[ -z "$kube" || ! -f "$kube" ]]; then
    echo "ERROR: Set STANDBY_KUBECONFIG to a kubeconfig that reaches the standby cluster" >&2
    echo "  Example:" >&2
    echo "    SB_IP=\$(terraform -chdir=cloud-services-gcp output -json standby_control_plane_ips | jq -r 'to_entries[0].value')" >&2
    echo "    ssh ubuntu@\$SB_IP 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/hybrid-standby.yaml" >&2
    echo "    # rewrite server: https://127.0.0.1:6443 → https://\$SB_IP:6443" >&2
    echo "    STANDBY_KUBECONFIG=~/.kube/hybrid-standby.yaml $0 activate-apps" >&2
    exit 1
  fi
  export KUBECONFIG="$kube"

  log "Step 1/5 — cluster reachability"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: kubectl --kubeconfig=${kube} get nodes"
  else
    kubectl get nodes
  fi

  log "Step 2/5 — optional Velero restore (manual; list backups)"
  if command -v velero >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN: velero backup get"
      echo "DRY-RUN: velero restore create failover-<ts> --from-backup <NAME> --wait"
    else
      velero backup get 2>/dev/null | head -20 || true
      echo "  If you need a restore:"
      echo "    velero restore create failover-\$(date +%s) --from-backup <NAME> --wait"
    fi
  else
    log "velero CLI not installed — skip restore list (install if you need restore)"
  fi

  log "Step 3/5 — scale common standby apps"
  local scaled=0
  for pair in linkding/linkding demo/demo-app; do
    ns="${pair%%/*}"
    dep="${pair##*/}"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN: kubectl -n ${ns} scale deploy/${dep} --replicas=1"
      scaled=1
    else
      if kubectl -n "$ns" scale "deploy/${dep}" --replicas=1 2>/dev/null; then
        scaled=1
      fi
    fi
  done
  if [[ "$scaled" -eq 0 && "$DRY_RUN" != "1" ]]; then
    echo "WARN: no known Deployments scaled (linkding/demo missing?). Check Argo/Velero." >&2
  fi

  log "Step 4/5 — Argo CD apps on standby (if installed)"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN: kubectl get applications -n argocd"
  else
    kubectl get applications -n argocd 2>/dev/null || log "No argocd namespace on standby"
  fi

  log "Step 5/5 — verify Traefik / DNS"
  echo "  kubectl get svc -A | grep -E 'traefik|LoadBalancer'"
  echo "  Confirm Cloud DNS app record points at standby_lb_ip (Level B)"
  echo "  terraform -chdir=cloud-services-gcp output standby_lb_ip"
  log "Level C operator path complete (Workflow did not automate this)"
}

failback_notes() {
  banner
  cat <<'EOF'

Failback (manual — no Workflow):

1. Confirm primary is healthy:
     curl -k https://PRIMARY_CP:6443/readyz
2. Reset witness state in Firestore document witness/health:
     consecutive_failures=0, failover_active=false
3. Wait for Cloud DNS primary health check to pass (TCP :443 on primary LB)
4. Scale down standby demo apps if desired:
     STANDBY_KUBECONFIG=... kubectl -n linkding scale deploy/linkding --replicas=0
5. Document the incident in docs/GCP-BOOTSTRAP-ISSUES.md if useful

See docs/PHASE-4-RUNBOOK.md
EOF
}

help() {
  cat <<EOF
Usage: $(basename "$0") <command> [--dry-run]

Commands:
  status          Levels A/B/C checklist + shared-services hints
  activate-apps   Level C: scale standby workloads (needs STANDBY_KUBECONFIG)
  failback-notes  Print manual failback steps
  help            This message

Examples:
  $0 status
  $0 activate-apps --dry-run
  STANDBY_KUBECONFIG=~/.kube/hybrid-standby.yaml $0 activate-apps

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
