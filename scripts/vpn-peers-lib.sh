#!/usr/bin/env bash
# vpn-peers-lib.sh — shared helpers for multi-peer WireGuard client management
# shellcheck disable=SC2034
# Sourced by vpn-peer-*.sh / vpn-bootstrap.sh / vpn-apply-peers.sh

vpn_peers_require_wg() {
  command -v wg >/dev/null 2>&1 || {
    echo "ERROR: wireguard-tools (wg) required" >&2
    echo "  macOS: brew install wireguard-tools" >&2
    echo "  Debian/Ubuntu: sudo apt-get install -y wireguard-tools" >&2
    exit 1
  }
}

vpn_peers_city_dir() {
  local city="$1"
  echo "${REPO_ROOT}/vpn-clients/${city}"
}

vpn_peers_dir() {
  local city="$1"
  echo "$(vpn_peers_city_dir "$city")/peers"
}

vpn_peers_ensure_dirs() {
  local city="$1"
  local dir peers
  dir="$(vpn_peers_city_dir "$city")"
  peers="$(vpn_peers_dir "$city")"
  mkdir -p "$dir" "$peers"
  chmod 700 "${REPO_ROOT}/vpn-clients" "$dir" "$peers" 2>/dev/null || true
}

vpn_peers_gen_keypair() {
  local priv="$1" pub="$2"
  if [[ ! -f "$priv" ]]; then
    umask 077
    wg genkey | tee "$priv" | wg pubkey >"$pub"
    chmod 600 "$priv" "$pub"
  fi
}

# Migrate legacy single-client keys (client.privatekey) → peers/laptop.*
vpn_peers_migrate_legacy() {
  local city="$1"
  local dir peers
  dir="$(vpn_peers_city_dir "$city")"
  peers="$(vpn_peers_dir "$city")"
  vpn_peers_ensure_dirs "$city"

  if [[ -f "${dir}/client.privatekey" && ! -f "${peers}/laptop.privatekey" ]]; then
    cp "${dir}/client.privatekey" "${peers}/laptop.privatekey"
    cp "${dir}/client.publickey" "${peers}/laptop.publickey"
    chmod 600 "${peers}/laptop.privatekey" "${peers}/laptop.publickey"
    if [[ ! -f "${peers}/laptop.address" ]]; then
      echo "10.66.0.2/32" >"${peers}/laptop.address"
      chmod 600 "${peers}/laptop.address"
    fi
    echo "==> Migrated legacy client.* → peers/laptop.*"
  fi
}

# Next free address in 10.66.0.0/24 (.1 = server)
vpn_peers_next_address() {
  local city="$1"
  local peers max=1 host f
  peers="$(vpn_peers_dir "$city")"
  shopt -s nullglob
  for f in "${peers}"/*.address; do
    host="$(cut -d. -f4 "$f" | cut -d/ -f1)"
    if [[ "$host" =~ ^[0-9]+$ ]] && (( host > max )); then
      max=$host
    fi
  done
  shopt -u nullglob
  if (( max >= 254 )); then
    echo "ERROR: no free addresses in 10.66.0.0/24" >&2
    exit 1
  fi
  echo "10.66.0.$((max + 1))/32"
}

vpn_peers_list_names() {
  local city="$1"
  local peers f name
  peers="$(vpn_peers_dir "$city")"
  shopt -s nullglob
  for f in "${peers}"/*.publickey; do
    name="$(basename "$f" .publickey)"
    echo "$name"
  done | sort
  shopt -u nullglob
}

vpn_peers_count() {
  local city="$1"
  vpn_peers_list_names "$city" | wc -l | tr -d ' '
}

# Write ansible extra-vars YAML for all peers (stdout)
vpn_peers_ansible_vars() {
  local city="$1"
  local dir peers name addr pubkey
  dir="$(vpn_peers_city_dir "$city")"
  peers="$(vpn_peers_dir "$city")"

  [[ -f "${dir}/server.privatekey" ]] || {
    echo "ERROR: missing ${dir}/server.privatekey — run vpn-bootstrap.sh" >&2
    exit 1
  }

  if [[ "$(vpn_peers_count "$city")" -eq 0 ]]; then
    echo "ERROR: no peers under ${peers}/ — add one with vpn-peer-add.sh" >&2
    exit 1
  fi

  echo "wg_server_private_key: $(cat "${dir}/server.privatekey")"
  echo "wg_server_public_key: $(cat "${dir}/server.publickey")"
  echo "wg_server_address: \"10.66.0.1/24\""
  echo "wg_peers:"
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    addr="$(cat "${peers}/${name}.address")"
    pubkey="$(cat "${peers}/${name}.publickey")"
    echo "  - name: ${name}"
    echo "    public_key: ${pubkey}"
    echo "    address: \"${addr}\""
  done < <(vpn_peers_list_names "$city")
}

vpn_peers_tf_endpoint() {
  local tf="${REPO_ROOT}/vpn-gateways-gcp"
  if [[ -n "${VPN_ENDPOINT:-}" ]]; then
    echo "$VPN_ENDPOINT"
    return
  fi
  if [[ -d "$tf" ]]; then
    terraform -chdir="$tf" output -raw vpn_public_ip 2>/dev/null || true
  fi
}

vpn_peers_tf_port() {
  local tf="${REPO_ROOT}/vpn-gateways-gcp"
  if [[ -n "${WIREGUARD_PORT:-}" ]]; then
    echo "$WIREGUARD_PORT"
    return
  fi
  if [[ -d "$tf" ]]; then
    terraform -chdir="$tf" output -raw wireguard_port 2>/dev/null || echo 51820
  else
    echo 51820
  fi
}
