# RFE-4762 status report

Progress report for
[RFE-4762](https://redhat.atlassian.net/browse/RFE-4762), covering the PRP
validation work Daniel F (Edge PM) asked for.

This file is the versioned copy of what gets posted to the ticket. Numbers
below are from real runs, not estimates; the live figures are on the
[test health dashboard](https://arthur-r-oliveira.github.io/ocp-abi-local-sno/).

Last updated: 2026-10-06.

---

## TL;DR

**PRP (IEC 62439-3) works on OpenShift SNO, and we can now prove it
repeatably and automatically. One real product defect blocks the Day-0
path, and we have a root cause and a proposed upstream fix for it.**

- **Validated** on OCP **5.0.0-rc.2** (RHCOS / RHEL 10.2) and **4.19.45**,
  two SNO clusters joined by a kernel `hsr` PRP link.
- **Zero packet loss across deliberate link cuts**, now demonstrated at
  scale: **1.5M UDP packets over 5 minutes with two 30-second LAN outages
  mid-run, no sequence gaps**, sub-millisecond RTT (p50 434 us).
- **Day-0 is blocked by an upstream `nmstate` defect.** PRP cannot be
  configured by the agent-based installer: `nmstate`'s offline keyfile
  writer has no `hsr` branch, so the generated profile is invalid and
  `prp0` never exists at first boot. Reproducible with stock `nmstatectl`,
  no OpenShift involved. We have the root cause in the source and a
  five-line proposed fix.
- **Day-2 works and is the supported-looking path.**
  `kubernetes-nmstate-operator` + an NNCP produces a correct `prp0`,
  matching the approach Red Hat's own HSR/PRP KB recommends.
- **Fully automated**: 3 CI workflows on a self-hosted KVM lab, from bare
  metal to a passing PRP failover and benchmark, reporting to a public
  dashboard. **14 runs, 132 test executions, 95.5% pass rate.**
- **Three defect reports are drafted and ready to file** (one upstream
  `nmstate`, two OpenShift-side). They are not filed yet - that is the main
  thing awaiting a decision.

**What we need from the RFE**: a steer on filing the three reports through
the right channels, and confirmation of which topologies matter for GA
(Test Case 3 and TNF are specified but not yet passing - see
[Not yet proven](#not-yet-proven)).

---

## What was asked, and what exists now

Three topologies were specified. Status:

| # | Topology | What it proves | Status |
|---|---|---|---|
| 1 | `single` | baseline SNO, no PRP | **Passing in CI** |
| 2 | `dual-sidecar-prp` | PRP as a side network between two SNOs | **Passing in CI**, incl. benchmark |
| 3 | `single-primary-prp` | PRP as the cluster's *primary* network under `br-ex` | **Blocked** - see below |

Plus TNF (Two-Node with Fencing), which is specified but needs its own
design pass (different install flow, virtual BMC, external load balancer).

## Results

### PRP behaves correctly at the protocol level

Not just IP reachability - the kernel's own PRP state:

- `prp0` present on both nodes with `proto 1` (PRP, not HSR)
- both slave ports carry **identical** packet counters: PRP duplicates
  every frame, it does not merely fail over
- `/sys/kernel/debug/hsr/prp0/node_table` registers the peer as `DAN-P: 1`
  (Dual Attached Node), populated from real supervision frames

### Zero loss across link cuts, under real traffic

The failover test cuts a link at the **hypervisor** level
(`virsh domif-setlink`) rather than inside the guest - closer to an
unplugged cable than a software reconfiguration, and a strictly stronger
test than the KB's own example.

| Test | Traffic | Result |
|---|---|---|
| `ping` failover, 8s outage | ~1 pkt/s | 97/97 packets, 0% loss |
| UDP benchmark, two 30s outages | 1500 msg/s, 450k packets | no sequence gaps, 14/14 assertions |
| UDP benchmark, two 30s outages | 5000 msg/s, 1.5M packets | no sequence gaps, 14/14 assertions |

**The zero-loss number alone would be worthless, and we treat it that
way.** PRP masks a dead LAN so completely that a test which cuts a link and
checks only for 0% loss passes identically whether the cut happened or
silently failed - verified by stubbing the cut to a no-op and watching
zero-loss still pass. Every run therefore also asserts that each cut
*actually degraded redundancy* and then recovered. Those assertions are
what make the result evidence.

### Automated end to end

Three workflows on a self-hosted KVM runner:
`sno-test-matrix.yml` (wipe → install both topologies → Day-2 PRP →
failover), `prp-test.yml` (daily failover check), `prp-bench.yml` (the UDP
benchmark, chained off the matrix). Results publish to a dashboard with
per-test and per-run history.

## Defects found

Three are drafted and **ready to file, not yet filed**. Drafts are in this
repo.

### 1. `nmstate`: no `hsr` support in offline keyfile generation (the blocker)

**The root cause of the Day-0 failure.** `NmConnection::to_keyfile()`
(`rust/src/lib/nm/nm_dbus/gen_conf/conn.rs`) has an explicit branch for
`bond`, `bridge`, `vlan`, `vxlan`, `sriov`, `macsec`, `vrf`, `veth`, `vpn`,
`infiniband` - and none for `hsr`. There is no `gen_conf/hsr.rs` at all.

Effect: the generated `prp0.nmconnection` has `type=hsr` but no `[hsr]`
section, NetworkManager refuses to load it
(`hsr: setting required for connection of type 'hsr'`), and `prp0` does not
exist after first boot.

Key points for the ticket:

- **Not an OpenShift bug.** Reproducible with stock `nmstatectl gc`, no
  installer involved. OpenShift inherits it.
- **Not a version mismatch.** Confirmed in the installed build (2.2.60) and
  still present on upstream `base` as of 2026-10-06.
- **Never implemented, not regressed**: the original HSR/PRP PR (#2469) and
  the later #3035 / #3046 all touched `nm_dbus/connection/` and nothing
  under `nm_dbus/gen_conf/`.
- The live D-Bus path handles `hsr` correctly, which is exactly why `nmcli`
  and the Day-2 operator both work.
- **`ipvlan` appears to have the same gap**, found while tracing this.
- We have a **five-line proposed fix** and offered to submit the PR.

Draft: `docs/upstream-issue-1-nmstate-hsr-gen-conf.md`

### 2. OpenShift agent-based installer: HSR/PRP unusable Day-0

Downstream tracking issue for #1, so the OpenShift side has its own record
of why Day-0 PRP does not work and what unblocks it.

Draft: `docs/upstream-issue-2-agent-based-installer-hsr.md`

### 3. `assisted-installer-agent`: HSR interfaces dropped from host inventory

The host inventory collector drops `hsr`-type interfaces entirely - its
vendored netlink library predates HSR support - so a node with a working,
correctly-configured `prp0` never reports it to `assisted-service`. Found
while working around #1.

Draft: `docs/upstream-issue-3-assisted-installer-agent-hsr-inventory.md`

### Non-defect findings (environmental, recorded for reproducers)

- **`kubernetes-nmstate-operator` is in no OCP 5.0 default catalog**
  (checked all three; confirmed via the subscription's own
  `ConstraintsNotSatisfiable` condition). Almost certainly a pre-GA catalog
  gap, not a removal - but it means PRP on 5.0 currently needs either a
  mirrored 4.22 catalog or the upstream operator. Worth confirming it
  lands in 5.0's catalog before GA.
- **Parallel SNO bootstrap fails under hypervisor contention** - starved
  `sno-a`'s kube-apiserver past its 2-minute deadline. Installs are now
  staggered. (`docs/finding-parallel-bootstrap-resource-contention.md`)
- **Mirror registry config is Day-0-only.** A cluster installed against one
  registry hostname cannot be pointed at another afterwards: credentials,
  CA trust and `ImageDigestMirrorSet` are all install-time artifacts.
- **Benchmark harness saturates around 5000 msg/s** on this hardware -
  1,020 `udpRcvbufErrors` (receiver socket buffer, after the packets
  arrived), not wire loss. Our tooling's ceiling, not a product limit.

## Not yet proven

Stated plainly so the RFE does not over-read the green numbers:

- **Test Case 3 (`single-primary-prp`) does not complete an install.** The
  Day-0 network bug has a confirmed workaround (hand-corrected keyfile
  merged into the ISO's Ignition), but a second, distinct `assisted-service`
  validation blocker stops it end to end: *"Host does not belong to machine
  network CIDRs"*. Not yet root-caused, and plausibly related to defect #3
  (if the inventory never reports `prp0`, a CIDR check against it cannot
  pass) - that link is untested.
  (`docs/spec-test-case-3-prp-primary.md`)
- **TNF is not started.**
- **Everything here is virtualised** - libvirt VMs with virtio NICs on one
  KVM host. No physical NICs, no real switches, no electrical-grade
  timing. The protocol behaviour is real; the timing numbers are not
  representative of hardware.
- **Scale is two nodes.** No multi-node PRP group, no redundancy box
  (RedBox), no SAN/DAN mix beyond the two DAN-Ps.
- **5.0.0-rc.2 is a release candidate**, not GA.

## Where the evidence lives

| What | Where |
|---|---|
| Full test case, root cause, verification | `docs/prp-test-case.md` |
| Dashboard (per-test, per-run history) | https://arthur-r-oliveira.github.io/ocp-abi-local-sno/ |
| Defect drafts | `docs/upstream-issue-{1,2,3}-*.md` |
| Test Case 3 spec + blocker | `docs/spec-test-case-3-prp-primary.md` |
| Repo | https://github.com/arthur-r-oliveira/ocp-abi-local-sno |
