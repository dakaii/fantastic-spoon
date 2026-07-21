#!/usr/bin/env bash
# vpn-monitoring-wire.sh — Auto-wire VPN gateway metrics into platform Prometheus
#
# 1. Discover primary node NAT CIDRs (scraper egress)
# 2. Ensure vpn_metrics_cidrs on the VPN gateway firewall (terraform apply)
# 3. Generate scrape snippet + helm upgrade kube-prometheus-stack (if kubectl works)
# 4. Apply GitOps PrometheusRules + Grafana dashboard
#
# Usage:
#   ./scripts/vpn-monitoring-wire.sh
#   SKIP_HELM=1 ./scripts/vpn-monitoring-wire.sh   # firewall + snippet only
#
# Env:
#   VPN_METRICS_CIDRS  optional comma-separated CIDRs (skip discovery)
#   KUBECONFIG         optional; otherwise tries gcp-deploy setup via inventory
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_VPN="${REPO_ROOT}/vpn-gateways-gcp"
OUT_DIR="${REPO_ROOT}/tmp"
SCRAPE_FILE="${OUT_DIR}/vpn-additional-scrape.yaml"
SKIP_HELM="${SKIP_HELM:-0}"

log() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v terraform >/dev/null 2>&1 || die "terraform required"
[[ -d "$TF_VPN" ]] || die "missing ${TF_VPN}"

# --- CIDRs -------------------------------------------------------------------
CIDR_LIST=()
if [[ -n "${VPN_METRICS_CIDRS:-}" ]]; then
  IFS=',' read -ra raw <<<"$VPN_METRICS_CIDRS"
  for c in "${raw[@]}"; do
    c="$(echo "$c" | tr -d '[:space:]')"
    [[ -n "$c" ]] && CIDR_LIST+=("$c")
  done
else
  while IFS= read -r line; do
    [[ -n "$line" ]] && CIDR_LIST+=("$line")
  done < <("${REPO_ROOT}/scripts/vpn-discover-metrics-cidrs.sh" 2>/dev/null || true)
fi

if [[ ${#CIDR_LIST[@]} -eq 0 ]]; then
  log "No primary CIDRs — leaving vpn_metrics_cidrs unchanged (defaults to admin_cidr)"
else
  log "Metrics allowlist: ${CIDR_LIST[*]}"
  # Build HCL list
  hcl="["
  first=1
  for c in "${CIDR_LIST[@]}"; do
    if [[ $first -eq 1 ]]; then first=0; else hcl+=", "; fi
    hcl+="\"${c}\""
  done
  hcl+="]"

  TFVARS="${TF_VPN}/terraform.tfvars"
  if [[ -f "$TFVARS" ]]; then
    if grep -q '^vpn_metrics_cidrs' "$TFVARS" 2>/dev/null; then
      if [[ "$(uname -s)" == "Darwin" ]]; then
        sed -i '' "s|^vpn_metrics_cidrs.*|vpn_metrics_cidrs = ${hcl}|" "$TFVARS"
      else
        sed -i "s|^vpn_metrics_cidrs.*|vpn_metrics_cidrs = ${hcl}|" "$TFVARS"
      fi
    else
      printf '\nvpn_metrics_cidrs = %s\n' "$hcl" >>"$TFVARS"
    fi
    log "Updated ${TFVARS}"
  else
    export VPN_METRICS_CIDRS
    # Comma form for gcp-deploy init
    VPN_METRICS_CIDRS="$(IFS=,; echo "${CIDR_LIST[*]}")"
    export VPN_METRICS_CIDRS
  fi

  log "Applying VPN firewall (vpn_metrics_cidrs)"
  (
    cd "$TF_VPN"
    terraform init -input=false >/dev/null
    terraform apply -auto-approve -input=false
  )
fi

# --- Scrape snippet ----------------------------------------------------------
mkdir -p "$OUT_DIR"
VPN_SCRAPE_OUT="$SCRAPE_FILE" "${REPO_ROOT}/scripts/vpn-prometheus-scrape-snippet.sh" >/dev/null
log "Scrape values: ${SCRAPE_FILE}"

if [[ "$SKIP_HELM" == "1" ]]; then
  log "SKIP_HELM=1 — not applying to cluster"
  echo "Manual: helm upgrade kube-prometheus-stack ... -f ${SCRAPE_FILE} --reuse-values"
  exit 0
fi

# --- Helm + GitOps -----------------------------------------------------------
ensure_kubeconfig() {
  if [[ -n "${KUBECONFIG:-}" && -f "${KUBECONFIG}" ]]; then
    return 0
  fi
  local inv="${REPO_ROOT}/ansible/inventory/primary-hosts.yml"
  local cp_ip=""
  if [[ -f "$inv" ]]; then
    # shellcheck source=inventory-utils.sh
    source "${REPO_ROOT}/scripts/inventory-utils.sh"
    cp_ip="$(inventory_first_control_plane_ip "$inv" 2>/dev/null || true)"
  fi
  if [[ -z "$cp_ip" ]]; then
    cp_ip="$(terraform -chdir="${REPO_ROOT}/primary-cluster-gcp" output -json primary_control_plane_ips 2>/dev/null \
      | jq -r 'to_entries[0].value // empty' 2>/dev/null || true)"
  fi
  [[ -n "$cp_ip" ]] || return 1

  local kc="${KUBECONFIG_PATH:-${HOME}/.kube/hybrid-primary.yaml}"
  mkdir -p "$(dirname "$kc")"
  ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "ubuntu@${cp_ip}" \
    "sudo cat /etc/rancher/k3s/k3s.yaml" >"$kc" 2>/dev/null || return 1
  if [[ "$(uname -s)" == "Darwin" ]]; then
    sed -i '' "s/127.0.0.1/${cp_ip}/" "$kc"
  else
    sed -i "s/127.0.0.1/${cp_ip}/" "$kc"
  fi
  chmod 600 "$kc"
  export KUBECONFIG="$kc"
  log "Using kubeconfig ${kc} (API ${cp_ip})"
}

if ! ensure_kubeconfig; then
  log "WARN: no kubeconfig — scrape file written; apply helm locally when primary is up"
  echo "  helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \\"
  echo "    -n monitoring -f ${SCRAPE_FILE} --reuse-values"
  echo "  kubectl apply -k gitops/infrastructure/primary/monitoring/"
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || die "kubectl required to apply scrape config"
command -v helm >/dev/null 2>&1 || die "helm required to apply scrape config"

if ! kubectl get ns monitoring >/dev/null 2>&1; then
  log "WARN: monitoring namespace missing — skip helm (bootstrap primary first)"
  exit 0
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null 2>&1 || true

log "Helm upgrade kube-prometheus-stack (VPN scrape)"
helm upgrade kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  -n monitoring \
  -f "$SCRAPE_FILE" \
  --reuse-values

log "Apply GitOps monitoring (VPN rules + dashboard)"
kubectl apply -k "${REPO_ROOT}/gitops/infrastructure/primary/monitoring/"

log "VPN monitoring wired. Grafana: kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
