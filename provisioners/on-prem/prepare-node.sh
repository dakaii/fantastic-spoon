#!/usr/bin/env bash
# prepare-node.sh — One-time OS prep for on-prem bare-metal servers
# Run on each physical server BEFORE Ansible bootstrap.
#
# Usage (on the server itself as root):
#   curl -fsSL <raw-url>/prepare-node.sh | sudo bash -s -- cp-1 server
#
# Or copy and run locally:
#   sudo ./prepare-node.sh cp-1 server
set -euo pipefail

HOSTNAME="${1:?Usage: prepare-node.sh <hostname> <server|agent>}"
NODE_ROLE="${2:?Usage: prepare-node.sh <hostname> <server|agent>}"

echo "==> Preparing on-prem node: ${HOSTNAME} (role: ${NODE_ROLE})"

hostnamectl set-hostname "$HOSTNAME"

apt-get update
apt-get install -y curl jq open-iscsi nfs-common

# Disable swap (required for k3s)
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Kernel modules for Kubernetes networking
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/99-kubernetes.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system

systemctl enable --now iscsid

mkdir -p /etc/rancher/k3s
cat > /etc/rancher/k3s/config.yaml <<EOF
node-label:
  - "node-role=${NODE_ROLE}"
  - "provisioner=on-prem"
EOF

echo "==> Node ${HOSTNAME} prepared. Add to ansible/inventory/ and run bootstrap-cluster.sh"
