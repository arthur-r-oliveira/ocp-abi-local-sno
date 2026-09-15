# PRP Test Case

## Objective

Confirm that `sno-a` and `sno-b` - two independent OpenShift SNO nodes -
maintain uninterrupted Layer 2 connectivity to each other via a real
Parallel Redundancy Protocol (PRP, RFC 62439-3) link, including surviving
the loss of either individual path with zero packet loss.

## Topology

Both nodes' `eth2`/`eth3` land on the same two isolated libvirt networks:

| Node   | eth2 (`prp-lan-a`) | eth3 (`prp-lan-b`) | `prp0` IP    |
|--------|--------------------|--------------------|--------------|
| sno-a  | 10.10.10.0/24 segment A | segment B | 10.10.10.1/24 |
| sno-b  | segment A | segment B | 10.10.10.2/24 |

`prp0` on each node is a Linux kernel `hsr` interface (`hsr` driver,
`protocol=prp`) binding both physical ports into one logical redundant
interface: every frame `prp0` sends goes out **both** ports simultaneously;
duplicates arriving from either path are suppressed on receive.
`eth2`/`eth3` carry no IP of their own - only `prp0` does.

## Root cause: why this needs a manual/Day-2 fix at all

The agent-based installer's Day-0 NMState config (`agent-config.yaml`,
generated from `templates/agent-config.yaml.j2`) declares `prp0` correctly:

```yaml
- name: prp0
  type: hsr
  state: up
  hsr:
    port1: eth2
    port2: eth3
    multicast-spec: 0
    protocol: prp
```

This **validates successfully** at ISO-build time (`nmstatectl gc` on the
build host, nmstate 2.2.60, accepts the schema and even correctly rejects a
first, wrong attempt at the config - see below). But OCP 4.19.45's
`openshift-install` embeds its own, different, older nmstate-to-
NetworkManager-keyfile translator, and **that** translator silently drops
every HSR-specific field. The resulting on-disk connection profile has
`type=hsr` but no `[hsr]` section at all:

```
[connection]
...
type=hsr
...
[ipv4]
...
```

NetworkManager then refuses to load it:
```
NetworkManager[1853]: <warn> [...] keyfile: load: "/etc/NetworkManager/system-connections/prp0.nmconnection":
  failed to load connection: invalid connection: hsr: setting required for connection of type 'hsr'
```
Net effect at first boot: `eth2`/`eth3` come up fine (including getting
their shared operational MAC via nmstate's `mac-address` override, which
*does* survive translation), but `prp0` simply doesn't exist:
```
$ ip -d link show prp0
Device "prp0" does not exist.
```

This is a version-mismatch bug between the *validating* nmstate (correct,
newer) and the *serializing* one embedded in the installer binary
(older, drops fields it doesn't recognize) - not something fixable by
changing the YAML schema further.

### An earlier wrong attempt, and what it taught us

The first version of the NMState config gave `eth2` and `eth3` **different**
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
`eth2` vs `eth3`) - it's to keep the hardware MACs unique, and instead set
`mac-address` in the *nmstate* config for `eth2`/`eth3` to one shared,
explicit, made-up value (`prp_mac_address` in `vars/main.yml`, distinct
between `sno-a` and `sno-b`). nmstate/NetworkManager then reprogram the
NIC's operational MAC to that shared value at bring-up time, on top of its
distinct factory MAC. This part of the pipeline **does** survive the
installer's translation and works correctly at first boot.

## Remediation

Rebuild the `prp0` connection with `nmcli`, which - on the guest's own
NetworkManager (1.52+ here) - correctly supports HSR/PRP once given valid
input; only the installer's *generator* is broken, not the guest's own NM:

```bash
ssh core@<node-ip> sudo bash -c '
  nmcli connection delete prp0 2>/dev/null
  nmcli connection add type hsr con-name prp0 ifname prp0 port1 eth2 port2 eth3
  nmcli connection modify prp0 hsr.prp yes
  nmcli connection modify prp0 ipv4.method manual ipv4.addresses <prp_ip>/24
  nmcli connection modify prp0 ipv6.method disabled
  nmcli connection down prp0; nmcli connection up prp0   # down/up, not just up - hsr.prp can otherwise not take effect
  rm -f /etc/NetworkManager/system-connections/prp0-*.nmconnection  # avoid a duplicate-uuid stale file
'
```
(substitute the real interface names if `net.ifnames` numbering differs -
these nodes use `enp7s0`/`enp8s0`, not literally `eth2`/`eth3`, at the
kernel level; the installer's udev rename map is what makes `eth2`/`eth3`
usable in `agent-config.yaml` in the first place)

This is **not durable** on its own - it's a live edit via SSH, not
something MCO/ignition manages, so nothing reapplies it after certain
resets. Lock it in with a `MachineConfig` (already in
`extra-manifests/99-prp0-hsr-interface-<node>.yaml`, one per node since the
IP/MAC/UUID differ):

```
export KUBECONFIG=<install_dir>/auth/kubeconfig
oc apply -f extra-manifests/99-prp0-hsr-interface-sno-a.yaml   # on sno-a's kubeconfig
oc apply -f extra-manifests/99-prp0-hsr-interface-sno-b.yaml   # on sno-b's kubeconfig
```
MCO will roll this out with **one reboot per node** (normal for any
file-level MachineConfig) - expected, not a fault.

## Verification

### 1. Interface state, both nodes

```
$ ip -d link show prp0
9: prp0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1494 qdisc noqueue state UP
    link/ether 52:54:00:aa:aa:01 brd ff:ff:ff:ff:ff:ff
    hsr slave1 enp7s0 slave2 enp8s0 sequence 1800 supervision 01:15:4e:00:01:00 proto 1
```
`proto 1` = PRP mode confirmed (not HSR/`proto 0` - `nmcli` will silently
create the connection with `hsr.prp` still `no` unless you explicitly set
it *and* cycle the connection down/up; check this every time).

### 2. Cross-node reachability

```
$ ssh core@192.168.130.101 -- ping -c3 -W2 10.10.10.2
PING 10.10.10.2 (10.10.10.2) 56(84) bytes of data.
64 bytes from 10.10.10.2: icmp_seq=1 ttl=64 time=1022 ms   <- first packet: ARP/mac-table warm-up
64 bytes from 10.10.10.2: icmp_seq=2 ttl=64 time=0.580 ms
64 bytes from 10.10.10.2: icmp_seq=3 ttl=64 time=0.479 ms
--- 10.10.10.2 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss
```

### 3. Both paths are actually carrying traffic (not just one active link)

Packet counters on the two slave ports should be **identical** - PRP
duplicates every frame onto both paths, it doesn't merely fail over:
```
$ ip -s link show enp7s0   (prp-lan-a)          $ ip -s link show enp8s0   (prp-lan-b)
RX: 3392 bytes 48 packets                       RX: 3392 bytes 48 packets
TX: 6660 bytes 82 packets                        TX: 6660 bytes 82 packets
```

### 4. Failover test: kill one path mid-traffic, confirm zero loss

This is the actual point of PRP, so test it at the hypervisor level (an
administrative link-down on the libvirt vNIC, not a guest-side toggle -
closer to an unplugged cable than a software reconfiguration):

```bash
# Find the vNIC MAC for prp-lan-a on the target node
virsh domiflist sno-a | grep prp-lan-a
#  vnet26   network   prp-lan-a   virtio   52:54:00:1a:9d:cd

# Start a continuous ping, then cut/restore mid-stream
ssh core@192.168.130.101 'ping -i 0.2 -w 20 10.10.10.2' > /tmp/prp_failover.log 2>&1 &
sleep 3
virsh domif-setlink sno-a 52:54:00:1a:9d:cd down    # cut prp-lan-a
sleep 8
virsh domif-setlink sno-a 52:54:00:1a:9d:cd up      # restore it
wait
```

**Actual result from this environment**, `prp-lan-a` down for 8 of the 20
seconds of continuous traffic:
```
--- 10.10.10.2 ping statistics ---
97 packets transmitted, 97 received, 0% packet loss, time 19873ms
rtt min/avg/max/mdev = 0.346/0.533/0.888/0.075 ms
```
**Zero packet loss, no latency spike, across the entire outage window.**
This is PRP working as designed: `prp0` kept sending/receiving over the
surviving path (`prp-lan-b`) for the whole 8-second outage, and traffic was
already flowing normally again before the link was even restored.

Confirm recovery:
```
$ ssh core@192.168.130.101 -- ip -br link show enp7s0
enp7s0    UP    52:54:00:aa:aa:01  <BROADCAST,MULTICAST,UP,LOWER_UP>
$ ssh core@192.168.130.101 -- ip -d link show prp0 | grep -o 'proto [0-9]'
proto 1
```

### Pass criteria summary

| Check | Expected | 
|---|---|
| `ip -d link show prp0` | exists, `proto 1` |
| Cross-node ping | succeeds, sub-ms after warm-up |
| Slave port counters | identical on both ports |
| Single-path failure, mid-traffic | **0% packet loss** for the duration |
| Link restore | both ports return to `UP`/`LOWER_UP`, `prp0` still `proto 1` |

All five passed in this environment on both `sno-a` and `sno-b`.
