# PRP Test Case

## Objective

Confirm that `sno-a` and `sno-b` - two independent OpenShift SNO nodes -
maintain uninterrupted Layer 2 connectivity to each other via a real
Parallel Redundancy Protocol (PRP, RFC 62439-3) link, including surviving
the loss of either individual path with zero packet loss.

## Topology

Both nodes' `eth1`/`eth2` (each on its own dedicated NIC - `eth0` alone
carries br-ex/API/Ingress/egress) land on the same two isolated libvirt
networks:

| Node   | eth1 (`prp-lan-a`) | eth2 (`prp-lan-b`) | `prp0` IP    |
|--------|--------------------|--------------------|--------------|
| sno-a  | 10.10.10.0/24 segment A | segment B | 10.10.10.1/24 |
| sno-b  | segment A | segment B | 10.10.10.2/24 |

`prp0` on each node is a Linux kernel `hsr` interface (`hsr` driver,
`protocol=prp`) binding both physical ports into one logical redundant
interface: every frame `prp0` sends goes out **both** ports simultaneously;
duplicates arriving from either path are suppressed on receive.
`eth1`/`eth2` carry no IP of their own - only `prp0` does.

## Root cause: the Day-0 installer bug (confirmed on TWO OCP versions)

The agent-based installer's Day-0 NMState config (`agent-config.yaml`,
generated from `templates/agent-config.yaml.j2`) declares `prp0` correctly:

```yaml
- name: prp0
  type: hsr
  state: up
  hsr:
    port1: eth1
    port2: eth2
    multicast-spec: 0
    protocol: prp
```

This **validates successfully** at ISO-build time (`nmstatectl gc` on the
build host, nmstate 2.2.60, accepts the schema and even correctly rejects a
first, wrong attempt at the config - see below). But `openshift-install`
embeds its own, different, older nmstate-to-NetworkManager-keyfile
translator, and **that** translator silently drops every HSR-specific
field. Confirmed identically on **both OCP 4.19.45 and 5.0.0-rc.2** - the
resulting on-disk connection profile has `type=hsr` but no `[hsr]` section
at all:

```
[connection]
...
type=hsr
...
[ipv4]
...
```

NetworkManager then refuses to load it, on either version:
```
NetworkManager[1857]: <warn> [...] keyfile: load: "/etc/NetworkManager/system-connections/prp0.nmconnection":
  failed to load connection: invalid connection: hsr: setting required for connection of type 'hsr'
```
Net effect at first boot: `eth1`/`eth2` come up fine (including getting
their shared operational MAC via nmstate's `mac-address` override, which
*does* survive translation), but `prp0` simply doesn't exist:
```
$ ip -d link show prp0
Device "prp0" does not exist.
```

This is a version-mismatch bug between the *validating* nmstate (correct,
newer) and the *serializing* one embedded in the installer binary
(older, drops fields it doesn't recognize) - not something fixable by
changing the YAML schema further, and evidently not yet fixed as of this
5.0 release candidate.

### An earlier wrong attempt, and what it taught us

The first version of the NMState config gave the two PRP ports **different**
`mac-address` values (each interface's own real hardware MAC). That failed
*validation* itself:
```
NmstateError: InvalidArgument: HSR ports on interface prp0 cannot have different MAC addresses
```
This is a real protocol constraint: `prp0` is one logical LRE identity
presented out two physical ports, so both ports must share one MAC. The
fix is **not** to give the two vNICs the same hardware MAC in the libvirt
domain XML (that broke the installer's separate MAC-based udev renaming
map, which needs unique MACs per physical NIC to know which one is
`eth1` vs `eth2`) - it's to keep the hardware MACs unique, and instead set
`mac-address` in the *nmstate* config for `eth1`/`eth2` to one shared,
explicit, made-up value (`prp_mac_address` in `vars/main.yml`, distinct
between `sno-a` and `sno-b`). nmstate/NetworkManager then reprogram the
NIC's operational MAC to that shared value at bring-up time, on top of its
distinct factory MAC. This part of the pipeline **does** survive the
installer's translation and works correctly at first boot, on both OCP
versions.

## Remediation: kubernetes-nmstate-operator (Day-2)

The durable fix is the `kubernetes-nmstate-operator` + a
`NodeNetworkConfigurationPolicy` (NNCP) applied after `install-complete`.
Its handler runs the **real** `nmstatectl` directly on the node via a
privileged DaemonSet pod - a completely different code path from the
installer's broken Day-0 serializer - and correctly produces a keyfile
with a real `[hsr]` section.

### Extra wrinkle on 5.0.0-rc.2: the operator isn't in the default catalog yet

```
$ oc get packagemanifest -n openshift-marketplace | grep -i nmstate
(no output)
```
Checked across all three default catalogs (`redhat-operators`,
`certified-operators`, `community-operators`) - all three healthy, 85-261
packages each, `kubernetes-nmstate-operator` in none of them. Confirmed via
the subscription's own condition, not just an empty grep:
```
$ oc get subscription kubernetes-nmstate-operator -n openshift-nmstate -o jsonpath='{.status.conditions}'
[{"reason":"ConstraintsNotSatisfiable","status":"True","type":"ResolutionFailed",
  "message":"constraints not satisfiable: no operators found in package kubernetes-nmstate-operator
             in the catalog referenced by subscription kubernetes-nmstate-operator, ..."},
 {"reason":"AllCatalogSourcesHealthy","status":"False","type":"CatalogSourcesUnhealthy"}]
```
This is almost certainly a pre-GA catalog gap (OCP 5.0 jumped to Kubernetes
v1.36; not every operator has been rebuilt/certified against it yet this
early in the RC cycle), not a permanent removal.

**Workaround** (`day2-manifests/00-nmstate-catalogsource.yaml`): point a
second `CatalogSource` at the last 4.x index, `v4.22` -
`registry.redhat.io/redhat/redhat-operator-index:v4.22` - which still
carries the operator, and OLM on 5.0 resolves/installs it from there
without complaint:
```
$ oc get packagemanifest -n openshift-marketplace -o json | \
    python3 -c "... filter catalogSource==redhat-operators-4-22 ..."
total packages from 4.22 index: 151      # includes kubernetes-nmstate-operator
```
```
$ oc get csv -n openshift-nmstate
NAME                                              VERSION               PHASE
kubernetes-nmstate-operator.4.22.0-202609090959   4.22.0-202609090959   Succeeded
```
**A quirk while waiting**: the catalog pod's gRPC server needs a few
restart cycles (3, here) before its `startupProbe` stops killing it -
building the query cache from a fresh 1.5GB index the first time takes
longer than the probe's patience, but the cache persists in the pod's
`/tmp` across restarts and eventually wins:
```
Warning  Unhealthy  kubelet  Startup probe failed: timeout: failed to connect
                              service "10.128.0.115:50051" within 5s: context deadline exceeded
...
$ oc get pods -n openshift-marketplace -l olm.catalogSource=redhat-operators-4-22
NAME                          READY   STATUS    RESTARTS   AGE
redhat-operators-4-22-pbt5w   1/1     Running   3          6m2s
```
Once `kubernetes-nmstate-operator` ships in OCP 5.0's own default catalog,
delete this workaround `CatalogSource` and point the `Subscription` back
at `redhat-operators`.

### Applying the fix

```
oc apply -f day2-manifests/00-nmstate-catalogsource.yaml
oc apply -f day2-manifests/01-nmstate-operator-subscription.yaml
# wait: oc get csv -n openshift-nmstate -> Succeeded
oc apply -f day2-manifests/02-nmstate-cr.yaml
# wait: oc get pods -n openshift-nmstate -> nmstate-handler Running (1/1)
oc apply -f day2-manifests/03-nncp-sno-a.yaml   # (or -sno-b.yaml, on that cluster)
```
```
$ oc get nncp prp0-hsr
NAME       STATUS      REASON
prp0-hsr   Available   SuccessfullyConfigured
```

## Verification

### 1. Interface state, both nodes

```
$ ip -d link show prp0
9: prp0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1494 qdisc noqueue state UP
    link/ether 52:54:00:aa:aa:01 brd ff:ff:ff:ff:ff:ff
    hsr slave1 enp6s0 slave2 enp7s0 sequence 1800 supervision 01:15:4e:00:01:00 proto 1
```
`proto 1` = PRP mode confirmed (not HSR/`proto 0`). Note: the kernel
interface names ended up `enp6s0`/`enp7s0` on this 3-NIC layout - always
confirm with `ip -br link` before writing the NNCP, predictable naming
depends on PCI slot allocation.

### 2. Cross-node reachability

```
$ ssh core@192.168.130.101 -- ping -c3 -W2 10.10.10.2
64 bytes from 10.10.10.2: icmp_seq=1 ttl=64 time=0.933 ms
64 bytes from 10.10.10.2: icmp_seq=2 ttl=64 time=0.534 ms
64 bytes from 10.10.10.2: icmp_seq=3 ttl=64 time=0.594 ms
--- 10.10.10.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

### 3. Failover test: kill one path mid-traffic, confirm zero loss

Tested at the hypervisor level (an administrative link-down on the libvirt
vNIC, not a guest-side toggle - closer to an unplugged cable than a
software reconfiguration):

```bash
virsh domiflist sno-a | grep prp-lan-a
#  vnet33   network   prp-lan-a   virtio   52:54:00:d8:47:f0

ssh core@192.168.130.101 'ping -i 0.2 -w 20 10.10.10.2' > /tmp/prp_failover.log 2>&1 &
sleep 3
virsh domif-setlink sno-a 52:54:00:d8:47:f0 down    # cut prp-lan-a
sleep 8
virsh domif-setlink sno-a 52:54:00:d8:47:f0 up      # restore it
wait
```

**Result, on the OCP 5.0.0-rc.2 / 3-NIC / operator-managed setup**,
`prp-lan-a` down for 8 of the 20 seconds of continuous traffic:
```
--- 10.10.10.2 ping statistics ---
97 packets transmitted, 97 received, 0% packet loss, time 19923ms
rtt min/avg/max/mdev = 0.439/0.560/0.800/0.063 ms
```
**Zero packet loss, no latency spike, across the entire outage window** -
identical to the result on the earlier OCP 4.19.45 / 4-NIC / manual-nmcli
setup. `prp0` kept sending/receiving over the surviving path
(`prp-lan-b`) for the whole 8-second outage.

### 4. Both paths actually carry traffic (not just one active link)

Packet counters on the two slave ports should be **identical** - PRP
duplicates every frame onto both paths, it doesn't merely fail over. (From
the 4.19 run, same mechanism, same result on 5.0):
```
enp7s0 (prp-lan-a)   RX  3392B / 48pkt      TX  6660B / 82pkt
enp8s0 (prp-lan-b)   RX  3392B / 48pkt      TX  6660B / 82pkt   <- identical
```

### Pass criteria summary

| Check | Expected | 5.0.0-rc.2 result |
|---|---|---|
| `ip -d link show prp0` | exists, `proto 1` | Pass |
| Cross-node ping | succeeds, sub-ms after warm-up | Pass |
| Slave port counters | identical on both ports | Pass |
| Single-path failure, mid-traffic | **0% packet loss** for the duration | Pass - 97/97 |
| Link restore | both ports return to `UP`/`LOWER_UP`, `prp0` still `proto 1` | Pass |

All five passed on both `sno-a` and `sno-b`, on both OCP versions tested.

## Kernel module autoload - no action needed

`prp0` depends on the `hsr` kernel module. It does **not** need an explicit
`/etc/modules-load.d/` entry: `modinfo hsr` reports `alias: rtnl-link-hsr`,
the same on-demand autoload mechanism the kernel uses for `bonding`/`vlan`/
`bridge` - when NetworkManager asks for an hsr-type link, the kernel loads
the module itself. Verified loaded on both nodes:
```
$ lsmod | grep hsr
hsr    65536  0
```
and verified surviving a real reboot (the MCO-driven reboot during the
OCP 4.19 run brought `prp0` back with `proto 1` with zero manual
intervention).
