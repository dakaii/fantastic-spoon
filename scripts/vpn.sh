#!/usr/bin/env bash
# vpn.sh — CLI for consumer VPN: connect / disconnect / status / deploy hints
#
# Usage:
#   ./scripts/vpn.sh up [city] [client]     # default: us laptop
#   ./scripts/vpn.sh down [city] [client]
#   ./scripts/vpn.sh status
#   ./scripts/vpn.sh ip                       # public egress (needs tunnel up)
#   ./scripts/vpn.sh deploy                   # print GHA deploy command
#   ./scripts/vpn.sh destroy                  # print GHA destroy command
#
# Requires: wireguard-tools (brew install wireguard-tools)
# Config:   vpn-clients/<city>/<client>-<city>.conf
#            (from ./scripts/vpn-bootstrap.sh or GHA artifact wireguard-client-<city>)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export REPO_ROOT
# shellcheck source=vpn-peers-lib.sh
# shellcheck disable=SC1091
source "$(dirname "$0")/vpn-peers-lib.sh"

CITY="${2:-us}"
CLIENT="${3:-laptop}"
REPO_SLUG="${GITHUB_REPOSITORY:-dakaii/fantastic-spoon}"

log() { echo "==> $*"; }

vpn_wg_conf_dir() {
  if command -v brew >/dev/null 2>&1; then
    echo "$(brew --prefix)/etc/wireguard"
  else
    echo "/etc/wireguard"
  fi
}

vpn_conf_path() {
  local city="$1" client="$2"
  echo "${REPO_ROOT}/vpn-clients/${city}/${client}-${city}.conf"
}

vpn_iface_name() {
  local city="$1" client="$2"
  echo "${client}-${city}"
}

vpn_iface_up() {
  local iface="$1"
  sudo wg show "$iface" &>/dev/null
}

cmd_up() {
  local city="$1" client="$2"
  local src iface dir installed

  vpn_peers_require_wg

  src="$(vpn_conf_path "$city" "$client")"
  [[ -f "$src" ]] || {
    echo "ERROR: missing ${src}" >&2
    echo "  Deploy: gh workflow run gcp-vpn.yml -R ${REPO_SLUG} -f city=${city}" >&2
    echo "  Or local: ./scripts/vpn-bootstrap.sh" >&2
    exit 1
  }

  iface="$(vpn_iface_name "$city" "$client")"
  dir="$(vpn_wg_conf_dir)"
  sudo mkdir -p "$dir"
  installed="${dir}/${iface}.conf"
  sudo install -m 600 "$src" "$installed"

  if vpn_iface_up "$iface"; then
    log "Tunnel already up (${iface})"
  else
    log "Bringing up ${iface} from ${installed}"
    sudo wg-quick up "$iface"
  fi

  cmd_status
  echo ""
  echo "Check egress: ./scripts/vpn.sh ip"
}

cmd_down() {
  local city="$1" client="$2"
  local iface dir installed

  vpn_peers_require_wg
  iface="$(vpn_iface_name "$city" "$client")"
  dir="$(vpn_wg_conf_dir)"
  installed="${dir}/${iface}.conf"

  if sudo wg-quick down "$iface" 2>/dev/null; then
    log "Tunnel down (${iface})"
    return 0
  fi

  if [[ -f "$installed" ]]; then
    if sudo wg-quick down "$installed" 2>/dev/null; then
      log "Tunnel down (${installed})"
      return 0
    fi
  fi

  local src
  src="$(vpn_conf_path "$city" "$client")"
  if [[ -f "$src" ]] && sudo wg-quick down "$src" 2>/dev/null; then
    log "Tunnel down (${src})"
    return 0
  fi

  if ! sudo wg show 2>/dev/null | grep -q .; then
    log "No active WireGuard tunnel"
    return 0
  fi

  echo "WARN: could not match interface name; active tunnels:" >&2
  sudo wg show
  echo "Try: sudo wg-quick down <interface-from-wg-show>" >&2
  exit 1
}

cmd_status() {
  local gw_ip gw_port

  if sudo wg show 2>/dev/null | grep -q .; then
    sudo wg show
  else
    echo "No active WireGuard tunnel."
    echo "Connect: ./scripts/vpn.sh up [city] [client]"
  fi

  if [[ -d "${REPO_ROOT}/vpn-gateways-gcp" ]] && [[ -f "${REPO_ROOT}/vpn-gateways-gcp/terraform.tfstate" || -d "${REPO_ROOT}/vpn-gateways-gcp/terraform.tfstate.d" ]]; then
    gw_ip="$(terraform -chdir="${REPO_ROOT}/vpn-gateways-gcp" output -raw vpn_public_ip 2>/dev/null || true)"
    gw_port="$(terraform -chdir="${REPO_ROOT}/vpn-gateways-gcp" output -raw wireguard_port 2>/dev/null || echo 51820)"
    [[ -n "$gw_ip" ]] && echo "Gateway endpoint: ${gw_ip}:${gw_port}"
  fi
}

cmd_ip() {
  local egress

  if ! sudo wg show 2>/dev/null | grep -q "latest handshake"; then
    echo "ERROR: tunnel not up — run: ./scripts/vpn.sh up" >&2
    exit 1
  fi

  for egress in \
    "https://ifconfig.me" \
    "https://api.ipify.org" \
    "https://icanhazip.com"; do
    if egress="$(curl -4 --connect-timeout 10 -s --retry 2 "$egress" 2>/dev/null)" && [[ -n "$egress" ]]; then
      echo "$egress"
      return 0
    fi
  done

  echo "WARN: could not resolve public IP (DNS or egress issue)" >&2
  echo "Try: dig +short ifconfig.me @1.1.1.1" >&2
  exit 1
}

cmd_deploy() {
  cat <<EOF
Deploy VPN gateway (GitHub Actions):

  gh workflow run gcp-vpn.yml -R ${REPO_SLUG} -f city=${CITY}
  gh run watch -R ${REPO_SLUG}

Download artifact wireguard-client-${CITY}, copy *.conf to vpn-clients/${CITY}/, then:

  ./scripts/vpn.sh up ${CITY} laptop

Local alternative (needs gcloud + terraform + ansible on your Mac):

  GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-deploy.sh vpn
EOF
}

cmd_destroy() {
  cat <<EOF
Destroy VPN gateway only (primary/standby untouched):

  gh workflow run gcp-vpn-destroy.yml -R ${REPO_SLUG}
  gh run watch -R ${REPO_SLUG}

Local:

  GCP_PROJECT=hybrid-k8s-dev ./scripts/gcp-vpn-destroy-ci.sh
  ./scripts/vpn.sh down ${CITY} ${CLIENT}   # if tunnel still up
  rm -rf vpn-clients/${CITY}                # optional — removes keys
EOF
}

usage() {
  cat <<EOF
Usage: ./scripts/vpn.sh <command> [city] [client]

Commands:
  up       Connect full-tunnel VPN (default city=us client=laptop)
  down     Disconnect
  status   Show wg show + gateway endpoint
  ip       curl -4 ifconfig.me (tunnel must be up)
  deploy   Print GitHub Actions deploy instructions
  destroy  Print GitHub Actions destroy instructions

Examples:
  ./scripts/vpn.sh up
  ./scripts/vpn.sh down
  ./scripts/vpn.sh ip
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    up) cmd_up "$CITY" "$CLIENT" ;;
    down) cmd_down "$CITY" "$CLIENT" ;;
    status) cmd_status ;;
    ip) cmd_ip ;;
    deploy) cmd_deploy ;;
    destroy) cmd_destroy ;;
    -h|--help|help|"") usage ;;
    *)
      echo "ERROR: unknown command: $cmd" >&2
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
