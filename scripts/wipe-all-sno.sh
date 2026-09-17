#!/usr/bin/env bash
# Destroys and undefines every VM this repo's playbook can create, across
# every topology, and removes their install directories - a clean slate
# before/between CI test-matrix runs. Does NOT touch libvirt networks
# (sno_playbook.yml manages those idempotently on every run) or anything
# under /root/secrets.
#
# Keep VM_NAMES in sync with every vars/topologies/*.yml's sno_nodes list.
#
# Usage: ./wipe-all-sno.sh

set -uo pipefail

SNO_STORAGE_BASE="${SNO_STORAGE_BASE:-/home/libvirt-images}"

VM_NAMES=(
  sno-single         # topology: single
  sno-a              # topology: dual-sidecar-prp
  sno-b              # topology: dual-sidecar-prp
  sno-prp-primary    # topology: single-primary-prp
)

echo "== Wiping all known SNO VMs =="
for vm in "${VM_NAMES[@]}"; do
  if virsh dominfo "$vm" >/dev/null 2>&1; then
    state=$(virsh domstate "$vm" 2>/dev/null)
    if [ "$state" != "shut off" ]; then
      echo "-> destroying $vm (was: $state)"
      virsh destroy "$vm" >/dev/null 2>&1 || true
    fi
    echo "-> undefining $vm"
    virsh undefine "$vm" >/dev/null 2>&1 || true
  else
    echo "-> $vm not defined, skipping"
  fi

  install_dir="${SNO_STORAGE_BASE}/sno-install/${vm}"
  if [ -d "$install_dir" ]; then
    echo "-> removing $install_dir"
    rm -rf "$install_dir"
  fi

  # Remove any /etc/hosts line this node added (matches the exact line
  # shape tasks/deploy_node.yml writes, keyed on "api.<vm>.").
  if grep -q " api\.${vm}\." /etc/hosts 2>/dev/null; then
    echo "-> removing /etc/hosts entry for $vm"
    sed -i "/ api\.${vm}\./d" /etc/hosts
  fi
done

echo
echo "== Done. Remaining domains: =="
virsh list --all
