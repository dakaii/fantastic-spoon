#!/usr/bin/env bash
# failover-gcp.sh — GCP Phase 4 Level C operator helpers (+ status for automation)
#
# Honest boundary:
#   Level A — Cloud Function witness (automated)
#   Level B — Cloud DNS primary/backup (when domain configured)
#   Level C — Apps on standby: this script (manual) OR Workflow→activate-apps CF
#             when enable_level_c_automation=true (after seed-standby-kubeconfig.sh)
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
  C  Apps        — scale standby Deployments (+ pause Argo sync)
                   Manual: this script | Auto: enable_level_c_automation=true
EOF
}

status() {
  banner
  echo ""
  local level_c="unknown"
  if [[ -d "${REPO_ROOT}/shared-services-gcp" ]]; then
    if [[ -f "${REPO_ROOT}/shared-services-gcp/terraform.tfstate" ]] || \
       [[ -d "${REPO_ROOT}/shared-services-gcp/.terraform" ]]; then
      log "shared-services-gcp outputs:"
      terraform -chdir="${REPO_ROOT}/shared-services-gcp" output 2>/dev/null || \
        log "No terraform outputs yet — apply shared-services-gcp first"
      level_c="$(terraform -chdir="${REPO_ROOT}/shared-services-gcp" output -raw level_c_automation_enabled 2>/dev/null || echo unknown)"
    else
      log "shared-services-gcp not applied yet"
    fi
  fi
  echo ""
  log "Level C automation enabled: ${level_c}"
  if [[ "$level_c" == "true" ]]; then
    echo "  Seed/refresh kubeconfig: ./scripts/seed-standby-kubeconfig.sh"
    echo "  Activate URI: terraform -chdir=shared-services-gcp output -raw activate_apps_function_uri"
  else
    echo "  Opt-in: seed secret → enable_level_c_automation=true → apply shared-services"
    echo "  Docs: docs/PHASE-4-RUNBOOK.md (Level C automated)"
  fi
  echo ""
  log "Level A — witness logs (if deployed):"
  echo "  gcloud functions logs read hybrid-k8s-witness --gen2 --region=\${GCP_REGION:-us-central1} --limit=20"
  echo ""
  log "Manual Level C:"
  echo "  STANDBY_KUBECONFIG=... $0 activate-apps [--dry-run]"
  echo "  $0 failback-notes"
}

activate_apps() {
  banner
  echo ""
  local kube="${STANDBY_KUBECONFIG:-}"
  if [[ -z "$kube" || ! -f "$kube" ]]; then
    echo "ERROR: Set STANDBY_KUBECONFIG to a kubeconfig that reaches the standby cluster" >&2
    echo "  Or use automation: ./scripts/seed-standby-kubeconfig.sh + enable_level_c_automation=true" >&2
    echo "  Example:" >&2
    echo "    SB_IP=\$(terraform -chdir=cloud-services-gcp output -json standby_control_plane_ips 2>/dev/null | jq -r 'to_entries[0].value')" >&2
    echo "    ssh ubuntu@\$SB_IP 'sudo cat /etc/rancher/k3s/k3s.yaml' > ~/.kube/hybrid-standby.yaml" >&2
    echo "    # rewrite 127.0.0.1 → \$SB_IP" >&2
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

  log "Step 2/5 — pause Argo automated sync (avoid replicas:0 selfHeal)"
  for app in linkding demo-app; do
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN: kubectl -n argocd patch application ${app} --type merge -p '{\"spec\":{\"syncPolicy\":null}}'"
    else
      kubectl -n argocd patch application "$app" --type merge \
        -p '{"spec":{"syncPolicy":null}}' 2>/dev/null || \
        log "Argo app ${app} not found (ok if not installed)"
    fi
  done

  log "Step 3/5 — optional Velero restore (manual; list backups)"
  if command -v velero >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN: velero backup get"
    else
      velero backup get 2>/dev/null | head -20 || true
      echo "  If you need a restore:"
      echo "    velero restore create failover-\$(date +%s) --from-backup <NAME> --wait"
    fi
  else
    log "velero CLI not installed — skip restore list"
  fi

  log "Step 4/5 — scale common standby apps"
  local scaled=0
  for pair in linkding/linkding demo-app/demo-app; do
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
    echo "WARN: no known Deployments scaled (linkding/demo-app missing?)." >&2
  fi

  log "Step 5/5 — verify Traefik / DNS"
  echo "  kubectl get svc -A | grep -E 'traefik|LoadBalancer'"
  echo "  terraform -chdir=cloud-services-gcp output standby_lb_ip"
  log "Level C complete"
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
4. Scale down standby demo apps:
     STANDBY_KUBECONFIG=... kubectl -n linkding scale deploy/linkding --replicas=0
     STANDBY_KUBECONFIG=... kubectl -n demo-app scale deploy/demo-app --replicas=0
5. Re-enable Argo automated sync on standby apps if you paused it
6. Document the incident in docs/GCP-BOOTSTRAP-ISSUES.md if useful

See docs/PHASE-4-RUNBOOK.md
EOF
}

help() {
  cat <<EOF
Usage: $(basename "$0") <command> [--dry-run]

Commands:
  status          Levels A/B/C + automation flag from Terraform
  activate-apps   Manual Level C (needs STANDBY_KUBECONFIG)
  failback-notes  Print manual failback steps
  help            This message

Automation:
  ./scripts/seed-standby-kubeconfig.sh
  # enable_level_c_automation = true in shared-services-gcp

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
