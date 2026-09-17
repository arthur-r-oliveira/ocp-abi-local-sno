#!/usr/bin/env bash
# Transparent SSH tunnel giving THIS machine (the workstation) direct
# IP-level access to the ocp-public network (192.168.130.0/24) where
# sno-a / sno-b live - without exposing or routing to the isolated PRP
# test networks (prp-lan-a/prp-lan-b, 10.10.10.0/24). Those stay
# unreachable from outside the KVM host on purpose: that isolation is
# the whole point of the PRP test topology.
#
# Requires sshuttle installed LOCALLY on this workstation:
#   dnf install sshuttle          # Fedora/RHEL
#   pip install --user sshuttle   # anywhere else
# The KVM host side needs nothing extra - sshuttle uploads and runs a
# small helper over the SSH session itself (python3, already present).
#
# Run this on the WORKSTATION, not the KVM host. Needs local sudo
# (sshuttle asks for it itself) to adjust this machine's routing table.
#
# Usage: ./prp-lab-tunnel.sh [ssh-user@]kvm-host

set -euo pipefail
if [ -z "${1:-}" ]; then
  echo "Usage: $0 [ssh-user@]kvm-host" >&2
  exit 1
fi
REMOTE="$1"
SUBNET="192.168.130.0/24"

if ! command -v sshuttle >/dev/null 2>&1; then
  echo "sshuttle not found. Install it first:" >&2
  echo "  dnf install sshuttle      # Fedora/RHEL" >&2
  echo "  pip install --user sshuttle" >&2
  exit 1
fi

echo "Tunneling ${SUBNET} via ${REMOTE}. Ctrl-C to stop (routes are cleaned up automatically)."
echo "Also run scripts/add-cluster-hosts.sh (on this workstation) so hostnames resolve to real IPs - sshuttle routes IPs, it doesn't do DNS."
exec sshuttle -r "${REMOTE}" "${SUBNET}"
