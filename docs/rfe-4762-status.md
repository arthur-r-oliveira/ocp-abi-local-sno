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

**PRP (IEC 62439-3) redundancy works on OpenShift SNO and is now proven
automatically and repeatably. A single upstream `nmstate` defect blocks
Day-0 entirely - and in the topology this RFE is really about, it leaves
the node with no network at all. We have the root cause, a five-line fix,
and four reports drafted.**

- **Validated** on OCP **5.0.0-rc.2** (RHCOS / RHEL 10.2) and **4.19.45**:
  two SNO clusters joined by a kernel `hsr` PRP link, correct at the
  protocol level (`proto 1`, identical counters on both ports, peer
  registered `DAN-P: 1` from real supervision frames).
- **Redundancy holds under load.** Cutting either LAN for 30 seconds
  mid-run, at 1500 and 5000 msg/s, the surviving path carries the full
  rate and recovers - **4/4 runs, 8/8 redundancy assertions in CI**.
  Sub-millisecond RTT (p50 434 us).
- **The absolute "zero packet loss" claim is not yet reproducible.** Best
  run is real: 1.5M packets, no sequence gaps, through two outages. But
  across four runs it passed twice and failed twice, at 0.29-0.4% loss.
  One failure is explained (receiver socket buffer); **one is not**. See
  [the open item](#open-zero-loss-is-intermittent). This does not affect
  the redundancy result, but we cannot assert zero loss on demand today.
- **Day-0 is blocked by an upstream `nmstate` defect.** Its offline keyfile
  writer has no `hsr` branch, so the generated profile is invalid and
  `prp0` never exists at first boot. **Not an OpenShift bug** -
  reproducible with stock `nmstatectl`, no installer involved.
  **Severity depends on topology**: as a side network the interface is
  silently absent and recoverable Day-2; as the **primary or only
  address-bearing interface - the substation/rail case this RFE targets -
  the node comes up with no connectivity whatsoever.** No DNS, no
  registry, no SSH; diagnosis needs a `dracut` shell on the console. A
  schema-valid config is accepted without complaint and silently does
  nothing.
- **Day-2 works and matches Red Hat's own guidance.**
  `kubernetes-nmstate-operator` + an NNCP produces a correct `prp0` - the
  approach our HSR/PRP KB explicitly recommends.
- **Fully automated**: 3 CI workflows on a self-hosted KVM lab, bare metal
  to passing failover and benchmark, publishing to a dashboard.
  **15 runs, 146 test executions, 95.2%.**
- **Four reports drafted, none filed**, with a deliberate order: **RHEL
  Jira first** (it is what creates a backport into a shipped package),
  then the upstream fix, then the two OpenShift-side items. Note Bugzilla
  is retired for new RHEL and OpenShift product bugs - these go to Jira at
  issues.redhat.com.
- **It must be filed as a Bug, not an RFE.** `gen_conf` never supported
  `hsr` - verified against upstream history, not inferred - so
  "enhancement" is the natural reading and the expensive one: RFEs are not
  normally backported, so 10.2 and 9.8 would never get a fix while the KB
  keeps telling customers the configuration is supported. **This single
  field decides whether any shipped release is fixed.**
- **The backport is mechanically routine.** The CentOS Stream `nmstate`
  package already carries upstream cherry-picks as spec patches, and our
  change is purely additive with no API, ABI, schema or dependency impact.
  The obstacle is justification, not risk - which is why this RFE is worth
  citing on the Jira.

**Asks**:

1. **Go-ahead to file, and backing for Bug over RFE on the RHEL Jira**,
   plus a z-stream backport request for 10.2 and 9.8. This is the one
   that decides whether customers on a shipped release ever get a fix;
   everything else here is reporting.
2. **Confirmation that `kubernetes-nmstate-operator` lands in OCP 5.0's
   default catalog before GA** - it is currently in none of the three, so
   every PRP deployment on 5.0 needs a workaround today. This one has
   someone else's schedule attached, so it is the most time-sensitive.
3. **Which topologies matter for GA** - Test Case 3 and TNF are specified
   but not passing (see [Not yet proven](#not-yet-proven)).
4. **A pointer to the original HSR/PRP request**, if it was raised through
   a Red Hat channel. The upstream feature request (`nmstate#2302`, still
   open) was filed by someone else, so we cannot currently cite "this is
   the feature committed to in X, and the offline half was never built" -
   which would be the strongest opening the Jira could have.

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
| UDP benchmark, two 30s outages | 1500 and 5000 msg/s | **redundancy assertions 4/4 runs**; zero-loss 2/4 |

**The zero-loss number alone would be worthless, and we treat it that
way.** PRP masks a dead LAN so completely that a test which cuts a link and
checks only for 0% loss passes identically whether the cut happened or
silently failed - verified by stubbing the cut to a no-op and watching
zero-loss still pass. Every run therefore also asserts that each cut
*actually degraded redundancy* and then recovered. Those assertions are
what make the result evidence - and they are the ones that pass
consistently.

### Open: zero-loss is intermittent

Across four benchmark runs, `zero-loss` passed twice and failed twice
(0.29% and 0.4%). The two failures have different causes: the 5000 msg/s
one came with 1,020 `udpRcvbufErrors` and is the receiver's socket buffer
discarding datagrams *after* they arrived - our harness, not the product.
The 1500 msg/s one had **no kernel drops at all** and real mid-stream
sequence gaps, and is **not yet explained**.

Stated plainly for the RFE: **PRP redundancy behaviour is solid and
repeatable; the absolute zero-loss claim is not yet something we can
assert on demand.** Candidates still open are sender-side pacing, the
`hsr` driver's duplicate-discard under sustained load, virtio/vhost queue
behaviour on this host, or prp-bench itself. Next step is repeated runs
correlated against the sample timeline, to see whether losses cluster
around the cut windows (which would implicate PRP) or spread through the
run (which would not). Detail: `docs/prp-test-case.md`.

### Automated end to end

Three workflows on a self-hosted KVM runner:
`sno-test-matrix.yml` (wipe → install both topologies → Day-2 PRP →
failover), `prp-test.yml` (daily failover check), `prp-bench.yml` (the UDP
benchmark, chained off the matrix). Results publish to a dashboard with
per-test and per-run history.

## Defects found

**Four reports drafted, none filed.** Two of them are the same `nmstate`
defect aimed at two different places, deliberately - and the order matters:

| Order | Report | Target | Why |
|---|---|---|---|
| 1 | `rhel-jira-nmstate-hsr-gen-conf.md` | Jira, project **RHEL**, component **nmstate** | Creates the backport path into a shipped package. An upstream merge alone delivers nothing to RHEL 10.2. |
| 2 | `upstream-issue-1-nmstate-hsr-gen-conf.md` | github.com/nmstate/nmstate | Where the code must land regardless - the RHEL package is a rebase of upstream, so a downstream-only fix is dropped at the next rebase. Five lines from an existing template, so likely a PR rather than an issue. |
| 3 | `upstream-issue-2-agent-based-installer-hsr.md` | Jira, project **OCPBUGS**, component **Assisted Installer** | Downstream tracking, so OpenShift has its own record of why Day-0 PRP fails. |
| 4 | `upstream-issue-3-assisted-installer-agent-hsr-inventory.md` | github.com/openshift/assisted-installer-agent (or OCPBUGS) | A separate defect, found while working around the first. |

**Bugzilla is retired** for new RHEL and OpenShift product bugs; all the
internal paths above are Jira at issues.redhat.com. No customer case is
attached to any of these - they were found during enablement testing and
would be filed proactively.

### 1. `nmstate`: no `hsr` support in offline keyfile generation (the blocker)

**The root cause of the Day-0 failure.** `NmConnection::to_keyfile()`
(`rust/src/lib/nm/nm_dbus/gen_conf/conn.rs`) has an explicit branch for
`bond`, `bridge`, `vlan`, `vxlan`, `sriov`, `macsec`, `vrf`, `veth`, `vpn`,
`infiniband` - and none for `hsr`. There is no `gen_conf/hsr.rs` at all.

Effect: the generated `prp0.nmconnection` has `type=hsr` but no `[hsr]`
section, NetworkManager refuses to load it
(`hsr: setting required for connection of type 'hsr'`), and `prp0` does not
exist after first boot.

**Severity is topology-dependent, and the bad case is the one this RFE
cares about:**

- `hsr` as a *secondary* interface (our Test Case 2): the node boots
  normally and the PRP interface is silently absent. Recoverable Day-2.
- `hsr` as the *primary or only address-bearing* interface (Test Case 3 -
  the substation / rail / IEC 62439-3 control-network case, where the
  entire point is protecting the one link that matters): **the node has no
  network connectivity at all.** No DNS, no reachable registry, no SSH.
  Diagnosis requires `rd.break` into a `dracut` emergency shell on the
  console, because no remote path to the machine exists.

Nothing surfaces the failure to the user: a schema-clean configuration is
accepted without complaint and then silently does nothing. The only
evidence is NetworkManager's journal, on a node that in the second case
cannot be reached.

Key points for the ticket:

- **Not an OpenShift bug.** Reproducible with stock `nmstatectl gc`, no
  installer involved. OpenShift inherits it.
- **Not a version mismatch.** Confirmed in the installed build (2.2.60) and
  still present on upstream `base` as of 2026-10-06.
- **Not a regression - verified against git history, not inferred.**
  `hsr` has never appeared in any file under `gen_conf/`, on any branch,
  in any commit (`git log --all -S'hsr' -- .../gen_conf/` is empty; the
  same query for `vrf` returns commits, confirming the method). All five
  commits touching HSR since `b23da648` (2023-11-20) stayed on the D-Bus
  side - the original HSR/PRP work (#2469) and the later #3035 and #3046
  all touched `nm_dbus/connection/` and nothing under `nm_dbus/gen_conf/`.
  The offline path has been broken since the feature's first commit,
  about two years. Still present in **2.2.62**, the current
  CentOS Stream 10 build.
- **Which is why classification matters.** "Never worked" normally argues
  for RFE and lower priority. The counter-argument, and the one the draft
  leads with: HSR/PRP was shipped **GA in RHEL 10.2** and documented in a
  customer-facing KB specifying exactly the schema in the reproducer,
  while one of the two paths consuming that schema silently emits an
  unloadable profile. That is a gap between stated support and actual
  behaviour, not a wishlist item. Fallback if triage disagrees: silently
  discarding a configured setting instead of erroring is a bug on any
  reading.
- **Backport is routine for this package.** CentOS Stream `nmstate`
  (2.2.62) already carries upstream cherry-picks as `git format-patch`
  files wired in via `Patch0001:` in the spec. Our change is purely
  additive, fires only when `self.hsr` is `Some`, and touches no API,
  ABI, schema or dependency - so the regression-risk case is short. The
  ask is 10.2 and 9.8 z-streams plus the next minor via CentOS Stream.
  **Unverified**: whether 9.8 actually needs it (GA from 9.8 per the KB,
  but only 10.2 was tested) and whether those are EUS streams.
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
  Note this explains only one of the two zero-loss failures; see the open
  item above.

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
| Defect drafts | `docs/rhel-jira-nmstate-hsr-gen-conf.md`, `docs/upstream-issue-{1,2,3}-*.md` |
| Test Case 3 spec + blocker | `docs/spec-test-case-3-prp-primary.md` |
| Repo | https://github.com/arthur-r-oliveira/ocp-abi-local-sno |
