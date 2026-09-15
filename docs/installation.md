# Installation: Dual SNO with PRP Cross-Connect

## What this deploys

Two independent Single Node OpenShift 4.19 clusters, `sno-a` and `sno-b`, on a
single KVM host, wired so their guest OSes can run a real Parallel Redundancy
Protocol (PRP, RFC 62439-3) link to each other over two isolated Layer 2
segments. Each node has 4 vNICs:

```
eth0, eth1 -> ocp-public   (NAT, shared)      cluster API / Ingress / egress
eth2       -> prp-lan-a    (isolated, shared) PRP LRE port1
eth3       -> prp-lan-b    (isolated, shared) PRP LRE port2
```

`prp-lan-a`/`prp-lan-b` are shared by *both* nodes and otherwise unreachable
(no DHCP, no routing, no host IP) - that's what lets `sno-a` and `sno-b`'s
`prp0` interfaces see each other over both redundant paths while staying
invisible to everything else.

```
                 ocp-public (192.168.130.0/24, NAT)
        ┌───────────────┬───────────────────┬───────────────┐
        │                                                    │
   ┌────┴────┐                                          ┌────┴────┐
   │  sno-a  │──eth2── prp-lan-a (10.10.10.0/24) ────────│  sno-b  │
   │ (8vCPU  │──eth3── prp-lan-b ─────────────────────── │ 16GB)   │
   │  16GB)  │                                           │         │
   └─────────┘                                           └─────────┘
      prp0 = eth2+eth3 (hsr driver, proto=prp)  10.10.10.1 / .2
```

## Prerequisites

- A KVM-capable host (`/dev/kvm` present). This was built on RHEL 10, 72
  vCPUs, 46GB RAM, 70GB `/` + 463GB `/home` (see "Storage" below for why
  the split matters).
- An OpenShift pull secret (console.redhat.com/openshift/install/pull-secret).
- An SSH public key for the `core` user on each node.
- `ansible-core` >= 2.16 plus the collections in `requirements.yml`
  (`community.libvirt`, `ansible.posix`, `community.general`). If your host
  can't pull the `ansible-navigator` EE image (needs registry.redhat.io
  auth), install directly instead:
  ```
  dnf install -y ansible-core
  ansible-galaxy collection install -r requirements.yml
  ```

## Configuration

Edit `vars/main.yml`:

- `pull_secret_path`, `ssh_public_key_path` - point these at real files
  **outside the git-tracked repo** (e.g. `/root/secrets/...`, mode 600).
  Never commit these.
- `sno_nodes` - list of node dicts (`vm_name`, `hostname`, `install_dir`,
  `ip_address`, `prp_ip_address`, `prp_mac_address`). Two entries ship by
  default (`sno-a`, `sno-b`). `prp_mac_address` must be **unique per node**
  but is otherwise arbitrary - see the PRP test case doc for why.
- `sno_vcpu` / `sno_ram_mb` - **8 vCPU is a hard floor**, not a preference:
  the agent-based installer's master-role validation rejects anything less
  and bootstrap never starts.
- `sno_storage_base` - where VM disks/ISOs live. Defaults to
  `/home/libvirt-images`. Do **not** point this at `/root` (QEMU's
  unprivileged `qemu` user can't traverse a 0700 home directory) or at a
  small root filesystem (see "Storage" below).

## Running it

```
cd ocp-abi-local-sno
ansible-playbook sno_playbook.yml
```

If you hit `ERROR: Ansible requires blocking IO on stdin/stdout/stderr` in a
sandboxed/non-tty shell, run it through a pty:
```
script -qec "ansible-playbook sno_playbook.yml" /tmp/deploy.log
```

The play: installs packages, defines/starts the 3 libvirt networks, then
loops `tasks/deploy_node.yml` once per entry in `sno_nodes` (install dir,
install-config.yaml, both disk images, VM definition, MAC extraction,
agent-config.yaml, ISO build, static DHCP reservation on `ocp-public`,
VM start, `/etc/hosts`). Expect ~10-20 minutes for the ansible run itself
(dominated by the two `openshift-install agent create image` calls), then
30-90 minutes of unattended cluster bootstrap per node after the VMs boot.

Track bootstrap/install with the installer's own tooling, once per node:
```
openshift-install agent wait-for bootstrap-complete --dir=<install_dir> --log-level=info
openshift-install agent wait-for install-complete   --dir=<install_dir> --log-level=info
```

## Storage: why `/home`, not `/root` or `/var/lib/libvirt/images`

Two SNO nodes' OS disks reliably reach 25-30GB+ *each* once real
installation writes start (well before the cluster finishes rolling out
operators) - this is not a small/incidental amount. If `/` is a modest-size
LV (as is common - ours was 70GB), the images alone can fill it, and
libvirt/QEMU auto-**pause** the VM on ENOSPC (`paused (I/O error)` in
`virsh domstate --reason`) rather than corrupt data. Recovering means: stop
the VM, relocate the disk files to a filesystem with real headroom, fix
SELinux context (`virt_image_t`) and permissions (`0711`, so the
unprivileged `qemu` user can traverse into it), redefine the domain against
the new path, restart. `sno_storage_base` + the playbook's
"Ensure VM storage base directory exists" / SELinux tasks do this
automatically now.

**Do not try to "fix" this by shrinking one XFS filesystem to grow
another** - XFS has no shrink operation at all (only `xfs_growfs`), so that
would mean backup -> destroy -> recreate -> restore, a vastly bigger and
riskier operation than just pointing VM storage at whichever filesystem
already has room.

## A hard-restart mid-install will visibly wreck cluster health for hours

If you `virsh destroy` (hard power-cycle) a node that's already past
bootstrap and rolling out operators - even to fix something unrelated like
the storage issue above - expect `oc get co` to show multiple operators
stuck `Progressing=True` / static-pod installers stuck at "revision N,
0 nodes have achieved revision N+1" for a long time afterward. This isn't
necessarily unrecoverable, but in practice a clean rebuild (wipe the
install dir, rerun the playbook) was faster and less error-prone than
nursing a disrupted single-node control plane back to health. Prefer
`virsh shutdown` (graceful) over `virsh destroy` on a node that's actively
installing, if you must intervene at all.

## Access

Per node, from the KVM host:
```
export KUBECONFIG=<install_dir>/auth/kubeconfig
oc get nodes
cat <install_dir>/auth/kubeadmin-password   # retrieve, don't hardcode elsewhere
```
Console: `https://console-openshift-console.apps.<hostname>.<sno_domain>`

`/etc/hosts` on the KVM host gets `api`, `console-openshift-console`,
`downloads-openshift-console`, and `oauth-openshift` entries per node
automatically. **`/etc/hosts` has no wildcard support** - `*.apps...`
entries are a silent no-op, not a wildcard match; list every route
hostname you actually need explicitly (the playbook and
`scripts/add-cluster-hosts.sh` both do this correctly).

### Reaching the VMs from a workstation that isn't the KVM host

The VMs only exist on the KVM host's private `ocp-public` NAT network
(`192.168.130.0/24`) - nothing routes there from outside by default, which
is correct and intentional for `prp-lan-a`/`prp-lan-b` but inconvenient for
`ocp-public`. Two scripts, meant to run **on the remote workstation**
(copy them there, or run over the same SSH session you'd use to reach the
KVM host):

- `scripts/prp-lab-tunnel.sh [user@]kvm-host` - wraps
  `sshuttle -r <kvm-host> 192.168.130.0/24`, transparently routing just
  that subnet through an SSH tunnel to the KVM host. No new listening
  service on the KVM host, no VPN software, and - deliberately -
  `10.10.10.0/24` (the PRP subnet) is never included, so the isolation that
  matters stays intact even with the tunnel up.
- `scripts/add-cluster-hosts.sh` - adds the same `/etc/hosts` entries
  described above, needed because `sshuttle` routes IPs, not names.

## Known limitation not yet automated

The agent-based installer's Day-0 NMState pipeline gets `eth0-eth3` set up
correctly but **cannot** stand up the `prp0` HSR/PRP interface itself - see
`docs/prp-test-case.md` for why, and for the `MachineConfig` (already in
`extra-manifests/`) that fixes it as a Day-2 step you must apply yourself
after `install-complete`:
```
export KUBECONFIG=<install_dir>/auth/kubeconfig
oc apply -f extra-manifests/99-prp0-hsr-interface-<node>.yaml
```
This is not yet wired into the playbook to apply automatically.
