# Upstream issue draft (2 of 2): OpenShift Agent-Based Installer

**Target**: Red Hat Bugzilla, component **Assisted Installer** (product:
OpenShift Container Platform) is likely the right primary path here,
since the actual generation of the Day-0 network config from
`AgentConfig`/`NMStateConfig` happens in assisted-service's territory
(confirmed by the on-node file layout - see "Evidence" below - not by
reading assisted-service's own source, which wasn't traced the way
nmstate's was for the companion issue). A GitHub issue against
`openshift/assisted-service` is a reasonable alternative or mirror if
that project takes issues directly; check current practice before filing.

**Status**: drafted, not filed. This is the **downstream tracking issue**
- the actual defect lives in `nmstate` (see
`upstream-issue-1-nmstate-hsr-gen-conf.md`). File that one first or
alongside this one, and link it here once it has a number.

**Why file this too, rather than only the nmstate issue**: three reasons.
1. Someone triaging Agent-Based Installer bugs needs to find this without
   already knowing it's actually an nmstate problem - the installer's own
   UX gives zero indication of that.
2. There's a real, currently-undocumented gap for one specific topology
   (HSR/PRP as the *primary* network) where no workaround exists at all,
   which is worth a tracked item regardless of who owns the eventual fix.
3. Whoever owns the vendored/packaged `nmstate` version bump on the
   installer side needs their own ticket to track picking that fix up
   once it lands upstream.

---

## Title

```
Agent-Based Installer: Day-0 `hsr` (HSR/PRP) interface config is silently non-functional (upstream nmstate gen_conf bug); total node connectivity loss if HSR is the primary network
```

## Body

### Summary

Declaring an `hsr`-type interface (HSR/PRP, IEC/RFC 62439-3) in
`agent-config.yaml`'s `networkConfig` - a legitimate, schema-valid
NMState construct that the installer accepts without complaint at
ISO-build time - produces a node that never actually gets that interface.
The generated NetworkManager keyfile has `type=hsr` but is missing the
entire `[hsr]` settings section, so NetworkManager refuses to load it and
the interface never exists at boot.

- If `hsr` is a **side interface** (node also has another NIC with
  normal IP connectivity): node installs fine, that one interface is
  just silently absent. Recoverable via Day-2
  `kubernetes-nmstate-operator` + `NodeNetworkConfigurationPolicy` once
  the cluster is up (confirmed working - see "Workaround" below).
- If `hsr` is the **primary/only address-bearing interface** (a
  legitimate topology for protecting the one link that matters, e.g.
  substation/rail control networks - not just a redundant side channel):
  the node gets **zero network connectivity at all**. No DNS, no ping, no
  reachable registry. Installation cannot proceed, and there is
  **currently no workaround** - Day-2 remediation is not reachable
  because there's no network path to apply it over.

The installer's own network pre-flight check surfaces this as a generic
DNS/HTTP failure, giving no indication that the actual cause is a
malformed NetworkManager profile - a user hitting this has no path to the
real cause without inspecting the node directly (which, in the
primary-interface case, requires dropping into a `dracut` emergency shell
via `rd.break`, since there's no SSH path either).

### Root cause (confirmed, not the installer's own code)

Traced to an upstream `nmstate` bug, not something in the Agent-Based
Installer or assisted-service's own logic: `nmstate`'s offline
configuration-generation mode (`nmstatectl gc`, the same mechanism used to
produce the Day-0 NetworkManager profile baked into the ISO) never
implemented an `hsr`-specific keyfile serializer, while the live-apply
path (D-Bus, used by `nmcli`/`kubernetes-nmstate-operator`) has one and
works correctly. Full trace and a minimal, installer-independent
reproduction (plain `nmstatectl gc` against a 3-interface YAML, no
OpenShift involved) is in the companion upstream issue:
`upstream-issue-1-nmstate-hsr-gen-conf.md` (link once filed).

Confirmed identically on:
- OpenShift 4.19.45
- OpenShift 5.0.0-rc.2

Same symptom, months apart in installer builds - consistent with "this
was never supported," not a regression in either release.

### Steps to reproduce

1. In `agent-config.yaml`, under a host's `networkConfig.interfaces`,
   declare two plain ethernet interfaces and one `hsr` interface binding
   them, with the `hsr` interface carrying the node's address (minimal
   example - adjust MACs/addresses as needed):
   ```yaml
   networkConfig:
     interfaces:
       - name: eth0
         type: ethernet
         state: up
         mac-address: "52:54:00:aa:aa:01"
         ipv4: { enabled: false }
       - name: eth1
         type: ethernet
         state: up
         mac-address: "52:54:00:aa:aa:01"
         ipv4: { enabled: false }
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
     routes:
       config:
         - destination: 0.0.0.0/0
           next-hop-address: 192.168.140.1
           next-hop-interface: prp0
   ```
   (`eth0`/`eth1` must share one `mac-address` - a real HSR/PRP protocol
   constraint correctly validated elsewhere, unrelated to this bug; noted
   so the repro is directly usable.)
2. `openshift-install agent create image --dir=<dir> --log-level=debug` -
   succeeds, no validation error surfaced.
3. Boot the resulting ISO with `prp0` as the only address-bearing
   interface.
4. Node never obtains any network connectivity. Installer's network
   pre-flight screen shows generic DNS/ping/HTTP failures with no
   indication of the actual cause.

### Evidence

Node-local confirmation (this topology has no SSH path once it fails):
added `console=tty0 console=ttyS0,115200n8` plus, for this investigation,
`rd.break=pre-pivot` to the ISO's kernel args (`coreos-installer iso kargs
modify`) to capture a dracut emergency shell over serial - after ignition
writes its files to `/sysroot` but before NetworkManager or the `hsr`
kernel module ever run.

Confirms the on-node file layout for how this installer stages Day-0
network config:
```
/sysroot/etc/assisted/manifests/nmstateconfig.yaml       # source NMStateConfig - correct
/sysroot/etc/assisted/network/host0/eth0.nmconnection
/sysroot/etc/assisted/network/host0/eth1.nmconnection
/sysroot/etc/assisted/network/host0/prp0.nmconnection    # staged keyfile - broken
/sysroot/etc/systemd/system/NetworkManager.service.wants/nmstate.service
```
`nmstateconfig.yaml` has a complete, correct `hsr:` block. The staged
`prp0.nmconnection` has `type=hsr` with no `[hsr]` section - identical
defect shape to feeding the same input directly to plain `nmstatectl gc`
on a non-OpenShift host (see companion nmstate issue).

Screenshots of the installer's own failure screen (generic DNS/HTTP
errors, no hint of the real cause): available, not reproduced inline
here since they're stored as local evidence files rather than pasted
images in this draft.

### Ask

1. **Track and consume the upstream `nmstate` fix** once it lands
   (`upstream-issue-1-nmstate-hsr-gen-conf.md` / its filed equivalent) -
   bump whatever `nmstate` version/vendoring the Day-0 ISO-build path
   uses.
2. **In the meantime**, two independent, smaller asks worth considering
   on their own:
   - Improve the network pre-flight check's diagnostics to distinguish
     "no interface ever came up because its NetworkManager profile is
     malformed" from a generic DNS/connectivity failure - would have
     surfaced this specific class of bug (and similar future ones) far
     faster, without needing console/kernel-arg surgery to even see the
     real cause.
   - Document, as a known limitation, that HSR/PRP-as-primary-network
     topologies currently have **no working Day-0 or Day-2 path** (Day-2
     `kubernetes-nmstate-operator` requires a reachable node/API, which
     doesn't exist here) - so anyone attempting this topology today knows
     up front rather than discovering it the hard way.

### Workaround (works only for the side-interface case)

For topologies where the `hsr`/PRP interface is *not* the node's only
connectivity (a normal NIC also exists for API/Ingress/egress):
`kubernetes-nmstate-operator` + a `NodeNetworkConfigurationPolicy` applied
Day-2, once the cluster is up, correctly configures the interface - it
goes through nmstate's live-apply/D-Bus path rather than the broken
offline-generation path, so it's unaffected by this bug. Confirmed
working in this environment. **Not usable** when HSR/PRP is the primary
network, since there's no way to reach the operator's handler on a node
with no network at all - see "Summary" above.
