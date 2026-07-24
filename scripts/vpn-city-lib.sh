#!/usr/bin/env bash
# vpn-city-lib.sh — Map city labels → GCP region/zone/subnet for VPN gateways
# shellcheck shell=bash
#
# Usage (source from other scripts):
#   # shellcheck source=vpn-city-lib.sh
#   source "$(dirname "$0")/vpn-city-lib.sh"
#   vpn_city_resolve us   # sets VPN_CITY VPN_REGION VPN_ZONE VPN_SUBNET_CIDR

vpn_city_resolve() {
  local city="${1:-${VPN_CITY:-us}}"
  city="$(echo "$city" | tr '[:upper:]' '[:lower:]')"

  # Allow explicit overrides
  if [[ -n "${VPN_REGION:-}" && -n "${VPN_ZONE:-}" ]]; then
    VPN_CITY="$city"
    VPN_SUBNET_CIDR="${VPN_SUBNET_CIDR:-$(vpn_city_default_subnet "$city")}"
    export VPN_CITY VPN_REGION VPN_ZONE VPN_SUBNET_CIDR
    return 0
  fi

  case "$city" in
    us)
      VPN_REGION="us-central1"
      VPN_ZONE="us-central1-a"
      VPN_SUBNET_CIDR="${VPN_SUBNET_CIDR:-10.50.0.0/24}"
      ;;
    hk)
      VPN_REGION="asia-east2"
      VPN_ZONE="asia-east2-a"
      VPN_SUBNET_CIDR="${VPN_SUBNET_CIDR:-10.50.1.0/24}"
      ;;
    *)
      echo "ERROR: unknown VPN city '${city}'. Known: us, hk" >&2
      echo "  Or set VPN_REGION + VPN_ZONE (+ optional VPN_SUBNET_CIDR) explicitly." >&2
      return 1
      ;;
  esac

  VPN_CITY="$city"
  export VPN_CITY VPN_REGION VPN_ZONE VPN_SUBNET_CIDR
}

vpn_city_default_subnet() {
  case "${1:-us}" in
    hk) echo "10.50.1.0/24" ;;
    *) echo "10.50.0.0/24" ;;
  esac
}

# Known cities for multi-state sync (order: default first)
vpn_city_known() {
  echo us
  echo hk
}

vpn_city_inventory_path() {
  local city="${1:?city}"
  local root="${REPO_ROOT:-}"
  if [[ -z "$root" ]]; then
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  fi
  echo "${root}/ansible/inventory/vpn-hosts-${city}.yml"
}

# GCS object key for a city's VPN terraform state (relative to bucket)
vpn_city_state_gcs_key() {
  local city="${1:?city}"
  echo "vpn-gateways-gcp/${city}/terraform.tfstate"
}
