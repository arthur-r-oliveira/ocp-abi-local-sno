# Spec: Test Case 3 — PRP as the Primary Network Under br-ex

**Status: IMPLEMENTED AND RUN. Result: Outcome A (installation does not
work out of the box) - directly confirmed with node-local evidence (not
just inferred from Test Case 2), see "Result" at the end of this document.
Worth reporting upstream (see "Escalation plan"), but not a hard blocker -
see "What Outcome A means" below for the actual priority.**

## Why this test case is different from Test Case 2

Test Case 2 (implemented, working) puts PRP on a **side network**: `sno-a`/
`sno-b` each keep a dedicated NIC for real cluster traffic (`ocp-public`) and
PRP is an isolated pair of extra NICs that carry nothing critical. If PRP
breaks there, the cluster doesn't notice.

Test Case 3 puts PRP **underneath br-ex** - the interface that carries the
node's actual IP, the API, Ingress, and egress. If PRP doesn't come up here,
the node has no network at all. This is the actual point of PRP in a real
substation/rail deployment (protecting the link that matters, not a side
channel), and it is a fundamentally higher-stakes test than Test Case 2.

**This spec's central hypothesis, stated up front**: the same Day-0 installer
bug documented in `docs/prp-test-case.md` (nmstate's offline
configuration-generation code path drops HSR-specific fields when writing
the NetworkManager keyfile - see that doc's "Root cause" section for the
exact source-level trace) almost certainly reproduces here,
because this test case deliberately avoids the one fix that works
(`kubernetes-nmstate-operator`, Day-2). Loading the `hsr` kernel module ahead
of time (requirement 2 below) does **not** work around that bug - Network
Manager never even attempts `ip link add type hsr` if the connection profile
it's given has no `[hsr]` section, so the module being resident in memory is
necessary but not sufficient.

**Working out of the box here is a "good to have" from a production-deployment
perspective, not a hard requirement** - if this hypothesis is right and it
doesn't work, that's worth reporting upstream, but it isn't a blocker for
anything else in this repo. See "Two possible outcomes" below for what
each result actually means for closing out this test case.

---

## Requirement 1: the playbook becomes topology-aware

Three modes, one playbook:

| Mode | `sno_topology` value | Nodes | NICs/node | PRP role |
|---|---|---|---|---|
| Test Case 1 | `single` | 1 | 1 | none |
| Test Case 2 (current) | `dual-sidecar-prp` | 2 | 3 | isolated side network between the two nodes |
| Test Case 3 (this spec) | `single-primary-prp` | 1 | 2 | **is** the primary network; br-ex forms on top of `prp0` |

### Proposed layout

```
vars/
  main.yml                        # sno_topology selector + shared vars (secrets, sizing, domain)
  topologies/
    single.yml
    dual-sidecar-prp.yml           # today's vars/main.yml content, moved here
    single-primary-prp.yml         # new, this spec
templates/
  vm-definition/
    single.xml.j2
    dual-sidecar-prp.xml.j2        # today's templates/vm-definition.xml.j2, moved here
    single-primary-prp.xml.j2      # new
  agent-config/
    single.yaml.j2
    dual-sidecar-prp.yaml.j2       # today's templates/agent-config.yaml.j2, moved here
    single-primary-prp.yaml.j2     # new
  networks/                        # unchanged location, new files added (see Requirement 2)
day0-manifests/
  99-hsr-module-autoload.yaml.j2   # new - see Requirement 2
```

`sno_playbook.yml` loads `vars/topologies/{{ sno_topology }}.yml` after
`vars/main.yml`, and selects
`templates/vm-definition/{{ sno_topology }}.xml.j2` /
`templates/agent-config/{{ sno_topology }}.yaml.j2` instead of a fixed path.
Rationale for separate template files per topology rather than one template
with `{% if sno_topology == ... %}` blocks throughout: the three modes differ
in *interface count and role*, not just a few values - conditional blocks
covering that much of the file would be harder to read than three short,
concrete files. `day2-manifests/` (the operator+NNCP fix, Test Case 2 only)
is unaffected by this change and stays out of scope for `single` and
`single-primary-prp`.

**This is a real refactor of the existing `dual-sidecar-prp` files (moving,
not rewriting them) - flagging that explicitly since it touches working,
tested code. Recommend doing it as its own commit, verified against Test
Case 2's existing `scripts/test-prp-failover.sh` passing unchanged, before
adding any Test Case 3 content on top.**

---

## Requirement 2: the KVM/network topology for Test Case 3

One node, two NICs:

```
eth0 -> prp-lan-a   eth1 -> prp-lan-b
              \        /
             prp0 = hsr(eth0, eth1), proto=prp
                     |
                   br-ex   (OVN-Kubernetes forms this automatically over
                     |      whichever interface carries the default route -
                  API/Ingress/egress    see "How br-ex finds prp0" below)
```

No `ocp-public` NIC at all in this mode - connectivity to the node exists
*only* through `prp0`.

### `prp-lan-a`/`prp-lan-b` connectivity: NAT, by design, for this PoC

**Decided**: this is a lab sandbox PoC. Physical dual-path redundancy (two
real cable runs, two real switches) is explicitly out of scope here - that's
the eventual production deployment's job to validate later on official
hardware, not something this environment needs to simulate. Real PRP puts LAN A and LAN B on the same destination network
via two physically independent paths; here, both `prp-lan-a` and
`prp-lan-b` are independent NAT libvirt networks sharing this host's one
connected uplink (`eno1`) underneath. That's sufficient and correct for
what this PoC is actually validating: the **OS/software mechanism** - Day-0
extra manifests, the NMState `hsr` config inside `AgentConfig`, and whether
`br-ex` forms over `prp0` - not physical-path failure independence.

New network definitions (`prp-lan-a-nat.xml.j2`, `prp-lan-b-nat.xml.j2` -
**not** reusing the existing isolated `prp-lan-a.xml.j2`/`prp-lan-b.xml.j2`
from Test Case 2, since isolated-vs-routable is a real behavioral
difference worth distinct file names), each a NAT network like
`ocp-public.xml.j2`, on distinct subnets.

State this scope plainly wherever this test case's results get presented:
this PoC proves the mechanism works (or doesn't - see "Two possible
outcomes"); it does not, and isn't meant to, prove physical redundancy.
That's the eventual production deployment's hardware validation to do, not
a gap in this PoC.

### `install-config.yaml`/`agent-config.yaml` implications

- `machineNetwork` in `install-config.yaml` must be the subnet `prp0` itself
  lives on (the NAT network's subnet - pick one, e.g. `192.168.140.0/24`,
  distinct from `ocp-public`'s `192.168.130.0/24` so both topologies could
  even coexist on the same host without collision if ever run side by side).
- `rendezvousIP` = `prp0`'s address, not any physical NIC's.
- Both `eth0`/`eth1` need the shared `prp_mac_address` override, same reason
  as Test Case 2: PRP requires both LRE ports to present one MAC.

---

## Requirement 2b: loading the `hsr` module at Day-0 via extra manifests

The agent-based installer picks up any manifests dropped into
`<install_dir>/openshift/*.yaml` before `openshift-install agent create
image` runs, and applies them the same way a MachineConfig applies on any
OpenShift cluster - just baked into the very first boot's ignition instead
of arriving as a later Day-2 MCO rollout+reboot.

New task in `sno_playbook.yml` (topology-conditional, or harmless to always
run):
```yaml
- name: "[{{ node.vm_name }}] Ensure Day-0 extra manifests directory exists"
  ansible.builtin.file:
    path: "{{ node.install_dir }}/openshift"
    state: directory
    mode: '0755'
  when: sno_topology == 'single-primary-prp'

- name: "[{{ node.vm_name }}] Place hsr module autoload as a Day-0 extra manifest"
  ansible.builtin.template:
    src: day0-manifests/99-hsr-module-autoload.yaml.j2
    dest: "{{ node.install_dir }}/openshift/99-hsr-module-autoload.yaml"
    mode: '0644'
  when: sno_topology == 'single-primary-prp'
```
placed in `deploy_node.yml` **before** the "Create Agent Installer ISO and
assets" task. Content is the same `MachineConfig` shape already proven in
`day2-manifests/04-hsr-module-autoload.yaml` - only the delivery mechanism
changes (Day-0 file vs. Day-2 `oc apply`).

**Caveat already stated above, repeating because it's the crux of this
whole test case**: this ensures the module is *available*, not that
NetworkManager *uses* it. It doesn't fix the known bug.

---

## Requirement 3: the nmstate manifest lives inside AgentConfig (no operator)

`templates/agent-config/single-primary-prp.yaml.j2` (new), shape:

```yaml
apiVersion: v1alpha1
kind: AgentConfig
metadata:
  name: {{ node.hostname }}
rendezvousIP: {{ node.prp_ip_address }}     # prp0's address - there is no other
hosts:
  - hostname: {{ node.hostname }}.{{ sno_domain }}
    interfaces:
      - name: eth0
        macAddress: "{{ node_macs.eth0 }}"
      - name: eth1
        macAddress: "{{ node_macs.eth1 }}"
    rootDeviceHints:
      deviceName: /dev/vda
    networkConfig:
      interfaces:
        - name: eth0
          type: ethernet
          state: up
          mac-address: "{{ node.prp_mac_address }}"
          ipv4:
            enabled: false
          ipv6:
            enabled: false
        - name: eth1
          type: ethernet
          state: up
          mac-address: "{{ node.prp_mac_address }}"
          ipv4:
            enabled: false
          ipv6:
            enabled: false
        - name: prp0
          type: hsr
          state: up
          hsr:
            port1: eth0
            port2: eth1
            multicast-spec: {{ prp_multicast_spec }}
            protocol: prp
          ipv4:
            enabled: true
            dhcp: false
            address:
              - ip: {{ node.prp_ip_address }}
                prefix-length: {{ prp_prefix_length }}
          ipv6:
            enabled: false
      dns-resolver:
        config:
          server:
            - {{ prp_lan_a_gateway }}
      routes:
        config:
          - destination: 0.0.0.0/0
            next-hop-address: {{ prp_lan_a_gateway }}
            next-hop-interface: prp0
```

The only structural difference from Test Case 2's Day-0 attempt: `prp0` now
carries the primary IP/route/DNS (previously that was `eth0`→`ocp-public`,
untouched by the bug; here it's the interface the bug actually breaks).
That's exactly why this test case is higher-stakes than Test Case 2's Day-0
attempt was.

### How br-ex finds `prp0`

No separate br-ex configuration needed *if* `prp0` comes up: OVN-Kubernetes's
node setup (`configure-ovs.sh`) auto-detects whichever interface currently
holds the default route and converts it into `br-ex` (creates the OVS
bridge, moves the IP/route onto it, enslaves the original NIC as a bridge
port). Since the NMState config above puts the default route on `prp0`,
`br-ex` should form over `prp0` automatically, with no explicit `br-ex` NMState
stanza required. This is unverified in practice for this repo (Test Case 2
never needed it, since `ocp-public`'s `eth0` was never `prp0`) - first real
confirmation of this mechanism happens if/when Phase 2 below is reached.

---

## Two possible outcomes

Working out of the box here is a **"good to have" from a
production-deployment perspective, not a hard requirement** - this is not a gating decision for
anything else in this repo. What it does mean: if Outcome A happens, that's
worth reporting upstream so it can get fixed for whoever eventually wants
this topology working, rather than silently filed away as an accepted
limitation nobody follows up on. It does not mean this test case blocks on
a fix, or that Outcome A represents a failed test - it's a legitimate,
useful result either way.

**Outcome A (still the likely result, per the confirmed bug on both OCP
4.19.45 and 5.0.0-rc.2)**: `prp0` never materializes. `eth0`/`eth1` come up
with no IP and no default route. The node never reaches its own rendezvous
API, agent registration never completes, bootstrap times out. No SSH, no
`oc`, nothing reachable - unlike Test Case 2's Day-0 failure, which just
left a side interface missing on an otherwise-healthy node.

**If Outcome A happens**: worth writing up as a reportable finding (see
"Escalation plan" below for what to capture) so it's easy to hand to
whoever wants to pursue a fix upstream - but doing so is a "nice to have
this raised" action, not a required one.

**Outcome B (installation works)**: `prp0` comes up, `br-ex` forms over it,
the node bootstraps and installs normally. Re-run the same failover
methodology as Test Case 2 (`virsh domif-setlink ... down` on one PRP path
mid-install and mid-steady-state) - but now proving something materially
stronger: that cutting one path doesn't just fail a side test, it doesn't
interrupt **cluster API reachability**, which is the actual point of
putting PRP under br-ex.

### Escalation plan (useful to have ready either way)

1. ~~Capture the exact same class of evidence already gathered for Test
   Case 2's Day-0 failure~~ - **done**, via the `rd.break` dracut-shell
   investigation above: node-local `nmstateconfig.yaml`/`prp0.nmconnection`
   comparison, confirming the same defect shape directly on this topology.
2. ~~Write up a minimal, self-contained reproduction~~ - **done, and
   sharper than originally planned**: traced to the exact `nmstate` source
   function responsible (`NmConnection::to_keyfile()`, missing an `hsr`
   branch that every comparable settings type has), and reproduced with
   plain `nmstatectl gc` alone - no agent-based install, KVM, or OpenShift
   needed at all. See `docs/prp-test-case.md`'s "Root cause" section.
3. File it upstream against **`nmstate`** specifically (not
   `openshift-install`/assisted-service - they're downstream consumers of
   a real gap in nmstate's offline configuration-generation feature, not
   the origin of it; confirmed the gap is still open on nmstate's own
   current upstream branch). A paste-ready issue template exists, kept
   private (not in this public repo, since it names internal
   infrastructure) - ask whoever holds this repo's context if you need it.
   Also worth a Red Hat support case referencing that `kubernetes-nmstate`
   Day-2 is a known workaround but structurally can't apply to any
   topology where the HSR/PRP interface carries primary node connectivity
   (no reachable node/API for the operator to target).
4. This repo will draft that report's content when Outcome A is confirmed;
   filing it into whatever tracker (Bugzilla, GitHub, a support case) is a
   decision for whoever owns that relationship, not something to file
   automatically on their behalf.

### Test plan built around not knowing which outcome you'll get

1. **Instrument for Outcome A before touching the installer.** Capture the
   VM's serial console to a log file from domain start
   (`<console type='pty'><target type='serial'/></console>` already exists
   in the vm-definition templates - redirect/tee it, or use
   `virsh console <vm> --safe` piped to a file) so kernel/NetworkManager
   boot messages are visible even with zero network reachability. If this
   test only relied on SSH/`oc` to observe results, Outcome A would be
   nearly undebuggable.
2. Deploy with `sno_topology: single-primary-prp`.
3. **Time-box the wait.** Don't let `openshift-install agent wait-for
   bootstrap-complete` run its full default timeout (40+ minutes) if there's
   no sign of network activity at all after a few minutes - check the
   console log and `virsh domifstat`/ARP table on the host's bridges first.
   If `eth0`/`eth1` never even come up with link state, or `prp0` never
   appears in the console's `ip link` equivalent boot messages, that's
   Outcome A - stop, capture the console log as evidence, don't wait out
   the full timeout for nothing.
4. If Outcome A: worth writing up per "Escalation plan" above so it's
   ready to hand off if anyone wants to pursue a fix upstream - a good
   to have, not a required follow-up. Worth noting *why* Test Case 2's
   Day-2-operator fix isn't a usable workaround here (there's no operator
   in this context) when writing that report up.
5. If Outcome B: run the full failover suite (extend
   `scripts/test-prp-failover.sh` with a `single-primary-prp` mode that
   checks `oc get nodes`/API reachability across the cut, not just a ping),
   and update this spec's status.

---

## Open questions before implementation

None outstanding - see "Resolved" below.

## Resolved

- **LAN-A/B connectivity**: NAT, sharing this host's one connected uplink.
  Physical dual-path redundancy is explicitly out of scope here - that's
  the eventual production deployment's job on official hardware later, not
  something this PoC needs to simulate. See
  "`prp-lan-a`/`prp-lan-b` connectivity" above.
- **Directory refactor scope**: yes, now - implemented alongside Test Case
  3, as its own commit, verified against `scripts/test-prp-failover.sh`
  before Test Case 3 content landed on top.
- **What Outcome A means**: working out of the box here is a good to have
  from a production-deployment perspective, not a hard requirement. Worth reporting
  upstream if it doesn't (see "Escalation plan" above), but this isn't a
  blocker, and Outcome A is a legitimate result, not a failed test.

---

## Result: Outcome A, confirmed

Deployed for real with `sno_topology: single-primary-prp` against this
repo's implementation (`vm-definition/single-primary-prp.xml.j2`,
`agent-config/single-primary-prp.yaml.j2`, `day0-manifests/99-hsr-module-autoload.yaml.j2`,
the new `prp-lan-a-nat`/`prp-lan-b-nat` networks). Playbook run itself
completed cleanly (`failed=0`) - the failure is entirely inside the
booted node, not the deployment tooling.

**The node never obtained network connectivity.** Serial console produced
no output (RHCOS's agent ISO appears to target the VGA console only here,
not `ttyS0`, so `virsh console`/PTY capture came back empty - a real
follow-up if console logging is wanted for this topology going forward:
add `console=ttyS0` to the kernel args, or capture over VNC as done here).
VNC framebuffer screenshots (`docs/evidence/test-case-3-network-failure-*.png`),
taken ~30+ seconds apart and identical in substance, show the agent
installer's own network pre-flight screen reporting total failure:

```
Check Errors
Get "https://quay.io": dial tcp: lookup quay.io on [::1]:53: read udp [::1]:...: connection refused
ping failure:
ping: quay.io: Name or service not known
nslookup failure:
:: communications error to ::1#53: connection refused
:: communications error to 127.0.0.1#53: connection refused
:: no servers could be reached
```

No DNS, no ping, no HTTP - consistent with **no interface on the node
having an IP address at all**, which is exactly what "`prp0` never
materializes" predicts here: `eth0`/`eth1` are deliberately IP-less in
this topology's NMState config (`ipv4.enabled: false` - `prp0` was
supposed to be the only address-bearing interface), so if `prp0` doesn't
come up, nothing does.

**Update - directly confirmed, not just inferred.** The initial run above
could not inspect the node directly (no network path to SSH in), so the
root cause was originally inferred from Test Case 2's evidence rather than
proven for this topology. Closed that gap with a targeted follow-up: added
`console=tty0 console=ttyS0,115200n8` to the ISO's kernel args
(`topology_needs_serial_console_debug` in
`vars/topologies/single-primary-prp.yml`, applied by a new task in
`tasks/deploy_node.yml` via `coreos-installer iso kargs modify`) to get
real boot-time serial output, then, on a second boot, manually added
`rd.break=pre-pivot` to drop into dracut's emergency shell **after ignition
writes its files to `/sysroot` but before the real root switches in** -
early enough that neither NetworkManager nor the `hsr` kernel module have
run yet, which matters: it rules out a module-load-timing explanation for
this topology's failure, not just the embedded-serializer one.

From that shell, `/sysroot/etc/assisted/manifests/nmstateconfig.yaml` (the
source `NMStateConfig`, i.e. the input to whatever generates the
NetworkManager profile) has a complete, correct `hsr:` block:
```yaml
    - hsr:
        multicast-spec: 0
        port1: eth0
        port2: eth1
        protocol: prp
      ipv4:
        address:
        - ip: 192.168.140.50
          prefix-length: 24
        dhcp: false
        enabled: true
      ipv6:
        enabled: false
      name: prp0
      state: up
      type: hsr
```
but `/sysroot/etc/assisted/network/host0/prp0.nmconnection` - the staged
keyfile `nmstate.service` will hand to NetworkManager at real boot - has
`type=hsr` and **no `[hsr]` section at all**:
```ini
[connection]
autoconnect=true
autoconnect-slaves=1
id=prp0
interface-name=prp0
type=hsr
uuid=fcd9e789-3883-51eb-aa9c-64012cfee9af
autoconnect-priority=1
[ipv4]
address0=192.168.140.50/24
...
[ethernet]
cloned-mac-address=52:54:00:AA:AA:10
```
No `[hsr]` stanza, no `port1`/`port2`, nothing. This is a **static artifact
already broken inside the ISO before the VM ever boots** - confirmed
directly on this exact topology, not inferred from Test Case 2. It also
settles the alternative explanation worth ruling out (a Day-0
manifest-injection or kernel-module-load-ordering problem, rather than the
translator itself): irrelevant here, since the keyfile is already missing
the required section regardless of module timing - even a perfectly-timed
`hsr` module load could not make NetworkManager honor settings that were
never written.

What's confirmed **directly, from this run**: total loss of connectivity
at the installer's network pre-flight check (stable across repeated
checks), **and** the generated `prp0.nmconnection` keyfile missing its
`[hsr]` section despite a correct source `NMStateConfig` - the same defect
shape as Test Case 2's directly-confirmed finding, now independently
reproduced on this topology rather than assumed from it.

This closes the test case as **complete, with a reportable-but-not-blocking
finding** - working out of the box is a good to have here, not a hard
requirement (see "What Outcome A means"). A ready-to-file writeup exists,
kept private (not in this public repo): OCP version `5.0.0-rc.2`, the exact
`agent-config.yaml` `networkConfig` block from
`templates/agent-config/single-primary-prp.yaml.j2`, the two screenshots
in `docs/evidence/`, the node-local `nmstateconfig.yaml`/`prp0.nmconnection`
comparison captured via the `rd.break` dracut shell above, and a pointer to
Test Case 2's direct keyfile-level evidence in `docs/prp-test-case.md` for
the root-cause mechanism. Filing it into an actual tracker
(Bugzilla/GitHub/support case) remains a
decision for whoever owns that relationship, and isn't required for this
test case to be considered done.
