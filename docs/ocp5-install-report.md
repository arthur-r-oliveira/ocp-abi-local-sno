# OCP 5 Install Report

**Three agent-based-installer SNO topologies on OpenShift 5.0.0-rc.2** -
what passed, what's a confirmed installer bug, and what we learned running
three SNO VMs on one 46GB KVM host. Markdown counterpart of the
[HTML report artifact](https://claude.ai/artifact/8D37A84CkpjMzLdmG1kpuC) -
keep both in sync when either changes.

Host: internal KVM lab (RHEL 10). Dates: 2026-09-17 to 2026-09-18. OCP: 5.0.0-rc.2.

**Status at a glance**

| Topology | Test Case | Result |
|---|---|---|
| `single` | 1 | PASS - clean install |
| `dual-sidecar-prp` | 2 | PASS - 0% loss failover |
| `single-primary-prp` | 3 | `nmstate` bug confirmed AND worked around (prp0 up, real PRP) - a second, now-root-caused bug in `assisted-installer-agent` blocks full install (see below) |
| 3 VMs concurrently | - | Host RAM oversubscribed -> CVO errors (resolved, documented) |

## 01. Three topologies, one playbook

One Ansible playbook, selected per run with `-e sno_topology=...`. Each
topology gets its own libvirt network layout, VM domain XML, and
AgentConfig template - templated from `vars/topologies/*.yml`, not
copy-pasted per node.

| Topology | Nodes | Sizing | NICs | PRP role |
|---|---|---|---|---|
| `single` | 1 | 8 vCPU / 16GB | 1 -> `ocp-public` | none - baseline sanity check |
| `dual-sidecar-prp` | 2 independent | 8 vCPU / 16GB each | 3 each -> ocp-public + prp-lan-a + prp-lan-b | sidecar link between two clusters, not in the critical path |
| `single-primary-prp` | 1 | 8 vCPU / 16GB | 2 -> prp-lan-a + prp-lan-b, `prp0` underlies `br-ex` | load-bearing for cluster networking, not a sidecar |

## 02. Results

### Test Case 1 - `single` - PASS

Deploy -> bootstrap-complete -> install-complete -> health check, run in
isolation, all clean.

```
PLAY RECAP **********************************************************
localhost  : ok=28  changed=10  unreachable=0  failed=0  skipped=5  rescued=0  ignored=0

INFO All cluster operators have completed progressing
INFO Install complete!

== Single SNO (no PRP) :: test suite ==
[PASS] cluster-health:sno-single - ClusterVersion Available, all operators healthy
[PASS] node-ready:sno-single - kubelet Ready
== Summary: 2 passed, 0 failed ==
```

### Test Case 2 - `dual-sidecar-prp` - PASS

Both clusters healthy, PRP running in proper PRP mode (not HSR), and a
hypervisor-level link cut on one of the two redundant paths loses **zero**
packets. Full writeup with charts: `docs/prp-hackathon-report.html`.

```
[PASS] cluster-health:sno-a - ClusterVersion Available, all operators healthy
[PASS] cluster-health:sno-b - ClusterVersion Available, all operators healthy
[PASS] prp0-mode:sno-a - proto=1 (PRP)
[PASS] prp0-mode:sno-b - proto=1 (PRP)
[PASS] prp0-reachability - 0% loss, sno-a -> sno-b over prp0
[PASS] failover-prp-lan-a - 0% packet loss with prp-lan-a down for 8s
[PASS] prp-node-table:sno-a - 2 peer entries
[PASS] prp-node-table:sno-b - 3 peer entries
== Summary: 8 passed, 0 failed ==
```

### Test Case 3 - `single-primary-prp` - confirmed installer bug, node-local evidence

The Day-0 NMState config for `prp0` is schema-valid and builds a clean
ISO, but `openshift-install`'s Day-0 network config generation drops the
entire `[hsr]` section from the generated keyfile. Because PRP is the
network underneath `br-ex` in this topology (not a sidecar), the node
never gets a working network at all - no SSH, no `oc`, nothing reachable.

Confirmed directly (not inferred) by adding a serial-console kernel arg
plus a one-time `rd.break` to drop into the boot's dracut shell *after*
ignition writes its files but *before* NetworkManager or the `hsr` kernel
module ever run - early enough to also rule out a module-load-timing
explanation, not just confirm the translator one:

```
$ cat /sysroot/etc/assisted/manifests/nmstateconfig.yaml   # source (input) - correct
    - hsr:
        multicast-spec: 0
        port1: eth0
        port2: eth1
        protocol: prp
      name: prp0
      state: up
      type: hsr

$ cat /sysroot/etc/assisted/network/host0/prp0.nmconnection   # staged keyfile (output) - broken
[connection]
type=hsr
          # no [hsr] section anywhere in the file
[ipv4]
address0=192.168.140.50/24
...
```

Correct input, broken output, baked into the ISO before the VM ever boots
- the same defect shape already confirmed on the sidecar topology, now
independently reproduced here rather than assumed from it.

**One real difference from Test Case 2 worth calling out plainly: there is
no Day-2 workaround for this topology.** The `kubernetes-nmstate-operator`
fix that works for Test Case 2 needs a reachable API server to apply its
`NodeNetworkConfigurationPolicy` - a node with zero network connectivity
has no way to reach one.

**Outcome, as decided with the team:** not a hard blocker on the plan -
out-of-box install for this exact topology is a *good to have* from a
production-deployment perspective, not a requirement, and worth reporting
upstream rather than silently accepted. Full root cause, KB alignment, and
evidence: `docs/spec-test-case-3-prp-primary.md`, `docs/prp-test-case.md`.

Root cause (traced to the actual upstream `nmstate` source, not a
guess) and two paste-ready draft issues (one for `nmstate` itself, one
tracking the downstream impact on the Agent-Based Installer):
`docs/upstream-issue-1-nmstate-hsr-gen-conf.md`,
`docs/upstream-issue-2-agent-based-installer-hsr.md`.

**Update: the bug above is now worked around, live, not just diagnosed.**
Since the root cause is a single missing keyfile section, a hand-correct
`prp0.nmconnection` - `nmstate`'s own correct output for everything else
about this input, plus the one missing `[hsr]` section - gets merged
directly into the ISO's real Ignition config (`coreos-installer iso
ignition show`/`embed`, wired into `tasks/deploy_node.yml` via
`scripts/embed-day0-file.py`), bypassing the broken translation path
entirely rather than waiting on it. Confirmed live over SSH:
```
$ ip -d link show prp0
4: prp0: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
    hsr slave1 enp1s0 slave2 enp6s0 sequence ... proto 1 ...
IP4.ADDRESS[1]: 192.168.140.50/24
```
`proto 1` - real PRP, same signature already proven on Test Case 2.

One correction along the way: Day-0 "extra manifests"
(`<install_dir>/openshift/*.yaml`) do **not** apply pre-boot at all - they
stage at `/etc/assisted/extra-manifests/` for the Machine Config Operator
to pick up once a cluster exists, confirmed via a `dracut rd.break` shell.
The `hsr`-module-autoload manifest never had any effect on this topology's
original failure; the kernel's `rtnl-link-hsr` alias autoloads the module
on demand regardless, with no preload needed.

**With `prp0` now fully working, a second, distinct, now-root-caused
blocker surfaced - a third upstream bug, in a third project.**
`assisted-service`'s own pre-install validation still reports `Host does
not belong to machine network CIDRs`, despite the node's live address
matching `install-config.yaml`'s declared `machineNetwork.cidr` exactly.
A full wipe + fresh redeploy reproduced both the working `prp0` and this
same validation failure identically, deterministically.

Root cause, confirmed by querying the node's `assisted-db` container
directly rather than guessing from logs: the stored host inventory has
entries for the two physical NICs only - `prp0` is **completely absent**,
even though the collector visibly walks it. Traced into
`assisted-installer-agent`'s inventory collector: its vendored `netlink`
library (`v1.2.1-beta.2`) has zero awareness of the `hsr` link kind
anywhere in its source - it predates HSR kernel support entirely, so the
interface record never makes it into what gets reported.
`assisted-service`'s own validator is correct given the data it's handed;
the defect is upstream of it. No workaround exists yet for this one -
unlike the `nmstate` bug, this gap is in what the node reports about its
own live state, not a static file this repo can hand-correct. Full trace:
`docs/spec-test-case-3-prp-primary.md`'s final update section and
`docs/upstream-issue-3-assisted-installer-agent-hsr-inventory.md`.

## 03. What "8vCPU/16GB x 3" actually costs on a 46GB host

Test Case 1 was deployed *alongside* the already-running `sno-a`/`sno-b`
pair rather than after wiping them - three SNO VMs at once, ~48GB of
combined requested RAM against 46GB of physical host RAM.

**Symptom: looked like a cluster bug, wasn't one.**

```
NAME      VERSION      AVAILABLE   PROGRESSING   SINCE   STATUS
version   5.0.0-rc.2   False       True          64m     Unable to apply 5.0.0-rc.2: an unknown error has occurred: MultipleErrors

$ oc get nodes
Unable to connect to the server: stream error: stream ID 1; INTERNAL_ERROR; received from peer
```

| Moment | Free RAM | Swap in use | API server |
|---|---|---|---|
| 3 VMs running concurrently | ~400-450MB | 4.8 -> 5.3GB, climbing | timing out |
| After wiping down to 2 VMs | 13GB | 633MB | normal |

Tearing down the contended VM (`sno-single`) recovered the host instantly,
and a full regression pass on `sno-a`/`sno-b` came back 8/8 clean - they
were never actually damaged, just starved. Re-running Test Case 1 in
isolation afterward passed cleanly end to end.

**Practical takeaway:**
- This host comfortably runs **two** 8vCPU/16GB SNO nodes at once. A third
  pushes it into swap and produces CVO/apiserver errors that look like a
  product bug but are host contention.
- `scripts/run-test-matrix.sh` already wipes between every phase, so the
  CI path never hits this - it only bit us here because Test Case 1 ran
  *alongside* a live demo pair instead of after wiping.
- If you need to demo two topologies simultaneously on one host, budget
  accordingly (32GB+ headroom above the two demo clusters) or use a
  second physical host.

## 04. RHEL 10 host gotchas worth knowing before you start

None of these are OCP bugs - they're EL10 packaging/permission specifics
that cost real time the first time through.

- **libvirt-daemon doesn't pull in networking or QEMU support.**
  `libvirt-daemon-driver-network` and `-qemu` are separate packages on
  EL10 - install them explicitly.
- **genisoimage doesn't exist on EL10.** Use `xorriso` instead for any
  ISO-building step.
- **qemu-kvm moved.** The binary lives at `/usr/libexec/qemu-kvm`, not
  `/usr/bin/`.
- **The unprivileged qemu user can't see into /root.** uid 107 can't
  traverse a 0700 home directory. VM storage has to live somewhere it can
  reach - this repo uses `/home/libvirt-images` with `0711` perms and the
  `virt_image_t` SELinux context.
- **ENOSPC pauses the VM, it doesn't corrupt it.** Each SNO's disk
  reliably hits 25-30GB+ during install. A full filesystem shows up as
  `paused (I/O error)` in `virsh domstate --reason` - relocate storage to
  a filesystem with headroom, fix ownership/SELinux, redefine the domain,
  resume.
- **XFS has no shrink.** Don't try to grow one LV by shrinking another
  when both are XFS - there's no shrink operation at all, only
  `xfs_growfs`. Point VM storage at whichever filesystem already has room
  instead.
- **A hard power-cycle mid-install wrecks cluster health for hours.**
  `virsh destroy` on a node that's already rolling out operators leaves
  `oc get co` stuck `Progressing=True` for a long time. Prefer `virsh
  shutdown`, or just wipe and rebuild - it's faster than nursing a
  disrupted single-node control plane back to health.

## 05. What's automated already

A CI-style matrix exists today for Test Cases 1 and 2 - wipe, deploy,
prove healthy, wipe, next topology, report. Not yet wired into cloud CI
(needs a self-hosted runner with real `virsh` access), but runs the same
way locally.

| Script | Does |
|---|---|
| `wipe-all-sno.sh` | Destroys/undefines every known SNO VM, cleans install dirs and `/etc/hosts` |
| `test-single.sh` | Test Case 1 health check: ClusterVersion Available, no degraded operators, node Ready |
| `test-prp-failover.sh` | Test Case 2: health + PRP mode + reachability + a real hypervisor-level link cut + kernel node-table check |
| `run-test-matrix.sh` | Orchestrates all of the above end to end and writes a markdown report |

`.github/workflows/sno-test-matrix.yml` runs `run-test-matrix.sh` on
`workflow_dispatch`, on a self-hosted runner labeled `kvm-prp-lab`, and
uploads the report + logs as build artifacts.

## 06. What's not covered yet: TNF

Two-Node OpenShift with Fencing + PRP is a fourth, deliberately separate
topology - not just another `-e sno_topology=...` value. It needs its own
design pass:

- **Different install flow.** Agent-based installer support for TNF
  starts at **OCP 4.22** - confirmed, supersedes an earlier read of the
  docs that only found IPI/UPI documented (that was against 4.20-era
  docs).
- **Needs a virtual BMC.** TNF's fencing credentials expect a real
  Redfish BMC per node; on a KVM lab that means `sushy-tools` backed by
  libvirt.
- **Needs an external load balancer.** Unlike SNO, a 2-node control plane
  needs something in front of it (Red Hat's own docs show a sample
  haproxy config forwarding 6443/80/443).

Deliberately out of this report and out of the current CI matrix -
tracked as its own follow-up spec.
