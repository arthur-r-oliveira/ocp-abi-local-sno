# Split Dual-SNO PRP Across Two Physical Hosts

## Context

Currently both SNO VMs (sno-a, sno-b) run on a single KVM host with libvirt isolated networks for PRP. We have two physical servers available:

| Host | FQDN | Role |
|------|------|------|
| Host A | hypervisor-a.lab.local | sno-a |
| Host B | hypervisor-b.lab.local | sno-b |

Running one SNO per host is closer to a real PRP deployment with actual physical separation. The PRP L2 segments must span both hosts.

## Approach

### Network Extension: VXLAN Tunnels

Two point-to-point VXLAN tunnels between hosts (one per PRP path):

| Tunnel | VNI | Bridge | Purpose |
|--------|-----|--------|---------|
| `vxlan-prp-a` | 100 | `virbr-prp-a` | PRP redundant path 1 (prp-lan-a) |
| `vxlan-prp-b` | 200 | `virbr-prp-b` | PRP redundant path 2 (prp-lan-b) |

Each host runs 2 commands per tunnel: create the VXLAN interface, attach it to the libvirt bridge. No daemons, no switch config, no FRR.

Example on Host A:

```bash
# PRP path 1
ip link add vxlan-prp-a type vxlan id 100 remote <HOST_B_LAB_IP> dstport 4789 dev <PHYS_IF>
ip link set vxlan-prp-a up
ip link set vxlan-prp-a master virbr-prp-a

# PRP path 2
ip link add vxlan-prp-b type vxlan id 200 remote <HOST_B_LAB_IP> dstport 4789 dev <PHYS_IF>
ip link set vxlan-prp-b up
ip link set vxlan-prp-b master virbr-prp-b
```

Host B mirrors this with `remote` pointing at Host A's lab IP.

### Management Network: NAT Per Host (same subnet)

Each host creates its own `ocp-public` NAT at 192.168.130.0/24 — identical to today. This means **zero IP changes** in manifests, vars, agent-config, or Day-2 scripts. Access the remote VM via SSH jump through its hypervisor:

```bash
ssh -J root@hypervisor-b.lab.local core@192.168.130.102
```

> Bridging onto the lab network would give direct access but requires knowing physical NIC names, allocating lab IPs, and changing every hardcoded IP. NAT is simpler.

### Ansible: New Playbook + New Topology (backward-compatible)

The existing `sno_playbook.yml` stays untouched — single-host mode keeps working. New files handle the split.

## New Files

### `inventory/split-hosts.yml`

Two-host inventory with VXLAN peer IPs and physical interface names (fill in after checking both hosts):

```yaml
all:
  vars:
    ansible_user: root
  hosts:
    hypervisor-a.lab.local:
      vxlan_remote_ip: "<HOST_B_LAB_IP>"
      vxlan_phys_dev: "<PHYS_IF on host A>"
    hypervisor-b.lab.local:
      vxlan_remote_ip: "<HOST_A_LAB_IP>"
      vxlan_phys_dev: "<PHYS_IF on host B>"
```

### `vars/topologies/dual-sidecar-prp-split.yml`

Copy of `dual-sidecar-prp.yml` with two additions:

- `hypervisor` field on each node in `sno_nodes`
- `vxlan_tunnels` list (VNI, bridge, dstport)

```yaml
sno_nodes:
  - vm_name: "sno-a"
    hypervisor: "hypervisor-a.lab.local"
    # ... rest identical to dual-sidecar-prp.yml ...
  - vm_name: "sno-b"
    hypervisor: "hypervisor-b.lab.local"
    # ... rest identical ...

vxlan_tunnels:
  - name: vxlan-prp-a
    vni: 100
    bridge: virbr-prp-a
    dstport: 4789
  - name: vxlan-prp-b
    vni: 200
    bridge: virbr-prp-b
    dstport: 4789
```

### `tasks/setup_vxlan.yml`

Creates VXLAN interfaces and attaches them to libvirt bridges. Idempotent (handles "already exists"). Skipped when `vxlan_tunnels` is not defined.

### `sno_playbook_split.yml`

Two-play playbook:

- **Play 1** (`hosts: all`): package install, libvirtd, firewalld, networks, VXLAN setup
- **Play 2** (`hosts: all`): `include_tasks: tasks/deploy_node.yml` with a filter so each host only deploys its own node:

```yaml
- name: Deploy each SNO node assigned to this host
  ansible.builtin.include_tasks: tasks/deploy_node.yml
  loop: >-
    {{ sno_nodes | selectattr('hypervisor', 'equalto', inventory_hostname) | list }}
  loop_control:
    loop_var: node
    label: "{{ node.vm_name }}"
```

### `scripts/fetch-kubeconfigs.sh`

Small helper that scp's the remote host's kubeconfig to a local temp dir so Day-2/test scripts can use it.

## Modified Files

### `scripts/test-prp-failover.sh`

Add env var overrides for remote virsh and SSH jumps:

- `VIRSH_A`, `VIRSH_B` — default to `virsh` (backward compat), set to `ssh root@<host> virsh` for split mode
- `SSH_JUMP_A`, `SSH_JUMP_B` — prepended to SSH_OPTS for reaching VMs through their hypervisor
- Replace the 3 hardcoded `virsh` calls (lines 108, 117, 126) with `$VIRSH_A`

### `scripts/apply-day2-prp.sh`

Add `SSH_JUMP_A`, `SSH_JUMP_B` env vars to the SSH commands that verify prp0 on nodes.

### `scripts/wipe-all-sno.sh`

Create a `scripts/wipe-all-sno-split.sh` wrapper that SSH's into each host and runs wipe locally.

## Files That Need NO Changes

| File | Why |
|------|-----|
| `tasks/deploy_node.yml` | Already host-agnostic (operates on `node` loop var) |
| `templates/vm-definition/dual-sidecar-prp.xml.j2` | References network names, not host-specific details |
| `templates/networks/*.xml.j2` | Identical on both hosts |
| `templates/agent-config/dual-sidecar-prp.yaml.j2` | IPs stay the same |
| `templates/install-config.yaml.j2` | No changes |
| `day2-manifests/*.yaml` | Reference kernel interface names, not hypervisor details |
| `vars/main.yml`, `vars/topologies/dual-sidecar-prp.yml` | Untouched |

## Prerequisites to Verify on Both Hosts

1. **Inter-host connectivity**: `ping <other-host>` + `ip route get <other-host-ip>` to find the physical interface name
2. **Firewall**: UDP 4789 open between hosts for VXLAN
3. **SSH keys**: passwordless root SSH from control node to both hosts
4. **Storage**: ~170GB free at `/home/libvirt-images` on both hosts
5. **KVM**: `/dev/kvm` present, `libvirtd` installable on both
6. **Secrets**: pull-secret and SSH key at `/root/secrets/` on both hosts
7. **MTU**: If physical path is 1500 MTU, VXLAN inner MTU set to 1400 (PRP adds 6-byte RCT). Jumbo frames (9000) on physical NICs eliminates this constraint.
8. **Mirror registry**: sno-a on host A must reach the mirror on host B (via NAT gateway -> lab network -> host B:8443)

## Verification

1. **Manual VXLAN test first** (de-risks everything):
   - Create tunnels on both hosts manually
   - `tcpdump -i vxlan-prp-a` on host B while pinging from a test netns on host A
   - Confirm L2 frames traverse

2. **Run split playbook**:
   ```bash
   ansible-playbook sno_playbook_split.yml -i inventory/split-hosts.yml -e sno_topology=dual-sidecar-prp-split
   ```

3. **Wait for install-complete** on both nodes (from control host, kubeconfigs fetched)

4. **Run Day-2**:
   ```bash
   ./scripts/apply-day2-prp.sh  # with SSH_JUMP vars set
   ```

5. **Run failover test**:
   ```bash
   VIRSH_A="ssh root@hypervisor-a virsh" \
   VIRSH_B="ssh root@hypervisor-b virsh" \
   ./scripts/test-prp-failover.sh
   ```

6. **Backward compat**: confirm single-host mode still works unchanged:
   ```bash
   ansible-playbook sno_playbook.yml -e sno_topology=dual-sidecar-prp
   ```
