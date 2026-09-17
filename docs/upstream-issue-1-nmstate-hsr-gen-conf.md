# Upstream issue draft (1 of 2): nmstate/nmstate

**Target**: https://github.com/nmstate/nmstate/issues (primary). A Red Hat
Bugzilla against the `nmstate` component is a reasonable alternative/mirror
if that's the preferred internal path instead of, or in addition to, the
public GitHub issue.

**Status**: drafted, not filed. This is the root-cause fix target - see
the companion draft (`upstream-issue-2-agent-based-installer-hsr.md`) for
the downstream tracking issue against the Agent-Based Installer side.

**Why this one first**: this is where the actual defect lives. Filing here
gets the real fix moving; the ABI-side issue exists to track *consuming*
that fix once it exists, and to get the interim risk documented for anyone
who hits this before then.

---

## Title

```
nmstatectl gc / gen_conf: NetworkManager keyfile for `hsr` interfaces is missing the [hsr] section
```

## Labels

`bug`, `kind/bug`, and whatever label nmstate uses for the NetworkManager
backend specifically (haven't confirmed the exact label taxonomy - check
the repo's label list before filing and adjust).

## Body

### Describe the bug

`nmstatectl gc` (offline configuration generation - the `gen_conf` Cargo
feature) produces a NetworkManager keyfile for an `hsr`-type interface
with `type=hsr` set but **no `[hsr]` section at all**. NetworkManager then
refuses to load the resulting profile:

```
NetworkManager[...]: <warn> keyfile: load: ".../prp0.nmconnection":
  failed to load connection: invalid connection: hsr: setting required for connection of type 'hsr'
```

and the interface never comes up (`ip -d link show prp0` → `Device
"prp0" does not exist.`).

The identical interface state, applied **live** instead of generated
offline (`nmstatectl set`, or `nmcli connection add type hsr ...`),
produces a working `hsr` interface with a correct settings group. Only the
offline/`gen_conf` keyfile-writing path is affected - the live D-Bus-apply
path is fine.

### Version

`nmstate 2.2.60` (`nmstate-2.2.60-2.el10_2.x86_64`, RHEL 10.2).

Also checked against the current `base` branch (upstream default branch,
HEAD `70fa58c95bb80ff0e619e74f06d225948cd89fe2` as of 2026-09-17): the same
gap is present there too. Not a regression that's already been fixed and
just hasn't shipped yet - it looks like `gen_conf` support for `hsr` was
simply never implemented.

### To Reproduce

```yaml
# hsr-state.yaml
interfaces:
- name: eth0
  type: ethernet
  state: up
  mac-address: "52:54:00:aa:aa:10"
  ipv4: { enabled: false }
  ipv6: { enabled: false }
- name: eth1
  type: ethernet
  state: up
  mac-address: "52:54:00:aa:aa:10"
  ipv4: { enabled: false }
  ipv6: { enabled: false }
- name: prp0
  type: hsr
  state: up
  hsr:
    port1: eth0
    port2: eth1
    multicast-spec: 0
    protocol: prp
  ipv4:
    enabled: true
    dhcp: false
    address:
      - ip: 192.168.140.50
        prefix-length: 24
```

```
$ nmstatectl gc hsr-state.yaml
```

Note: `eth0`/`eth1` must share one `mac-address` in this example - HSR
validation correctly rejects differing port MACs (one logical LRE
identity presented out two ports), and that's not related to this bug;
included only so the repro is directly copy-pasteable.

### Expected behavior

The generated `prp0.nmconnection` includes a populated `[hsr]` section:
```ini
[hsr]
port1=eth0
port2=eth1
multicast-spec=0
prp=true
```
matching what the same input produces via `nmstatectl set` on a live
system.

### Actual behavior

```ini
[connection]
autoconnect=true
autoconnect-slaves=1
id=prp0
interface-name=prp0
type=hsr
uuid=fcd9e789-3883-51eb-aa9c-64012cfee9af

[ipv4]
address0=192.168.140.50/24
dhcp-timeout=2147483647
method=manual
...

[ethernet]
cloned-mac-address=52:54:00:AA:AA:10
```
No `[hsr]` section anywhere in the file.

### Suspected root cause (traced in source, tag `v2.2.60`)

The in-memory model is correct in **both** modes - this isn't a data
problem, it's a serialization gap in exactly one of two parallel writers.

`settings/connection.rs` (shared by both `gen_conf` and live-apply)
unconditionally dispatches:
```rust
Interface::Hsr(iface) => {
    gen_nm_hsr_setting(iface, &mut nm_conn);
}
```
and `settings/hsr.rs`'s `gen_nm_hsr_setting()` correctly populates
`nm_conn.hsr` with `port1`, `port2`, `interlink`, `multicast_spec`, `prp`,
`protocol_version` regardless of which mode is calling it.

The two modes only diverge at the final serialization step:

- **Live apply** → `nm_dbus/dbus.rs`'s `connection_add()` /
  `connection_update()` → `NmConnection::to_value()`
  (`nm_dbus/connection/conn.rs`), which has:
  ```rust
  if let Some(hsr) = &self.hsr {
      ret.insert("hsr", hsr.to_value()?);
  }
  ```
  backed by `nm_dbus/connection/hsr.rs`'s `ToDbusValue` impl for
  `NmSettingHsr` - **present and correct**.

- **Offline generate** (`gc`) → `nm/gen_conf.rs`'s `nm_gen_conf()` →
  `NmConnection::to_keyfile()` (`nm_dbus/gen_conf/conn.rs`) - this function
  has an explicit branch for every other optional settings type (`bond`,
  `bond_port`, `bridge`, `bridge_port`, `ovs_bridge`, `ovs_port`,
  `ovs_iface`, `ovs_patch`, `ovs_dpdk`, `wired`, `vlan`, `vxlan`, `sriov`,
  `mac_vlan`, `macsec`, `vrf`, `veth`, `user`, `ieee8021x`, `ethtool`,
  `infiniband`, `ovs_ext_ids`, `ovs_other_config`, `vpn`, `iface_match`) -
  and **none for `hsr`**. There is also no `hsr.rs` module at all under
  `nm_dbus/gen_conf/`, unlike every type just listed, each of which has
  its own file there implementing `ToKeyfile`.

So `self.hsr` is fully populated by the time `to_keyfile()` runs, but that
function simply never looks at it.

### Suggested fix

Add `rust/src/lib/nm/nm_dbus/gen_conf/hsr.rs` implementing `ToKeyfile for
NmSettingHsr` - the field list is small and already known
(`port1`/`port2`/`interlink`/`multicast-spec`/`prp`/`protocol-version`),
and `vrf.rs` or `veth.rs` in the same directory are reasonable templates
for the shape (a small optional settings struct with a handful of scalar
fields). Then wire it in:
- `nm_dbus/gen_conf/mod.rs`: add `mod hsr;`
- `nm_dbus/gen_conf/conn.rs`'s `NmConnection::to_keyfile()`: add
  ```rust
  if let Some(hsr_set) = &self.hsr {
      sections.push(("hsr", hsr_set.to_keyfile()?));
  }
  ```
  alongside the existing branches.

Happy to submit a PR for this if a maintainer confirms the approach and
there isn't a reason `hsr` was deliberately left out of `gen_conf`
(couldn't find one in the source or CHANGELOG, but flagging the
possibility rather than assuming).

### Downstream impact (context, not part of the ask)

This affects any consumer of nmstate's offline/`gen_conf` mode for `hsr`
interfaces - concretely, OpenShift's Agent-Based Installer, where an
`hsr` interface declared for Day-0 network configuration silently fails
to come up at first boot, with no error surfaced anywhere the installer's
own tooling shows the user - only visible via NetworkManager's journal on
the (possibly otherwise unreachable) node itself. A separate downstream
tracking issue covers that side; linking here once both exist.
