# ocp-abi-local-sno

[![SNO test matrix (wipe + single + dual-sidecar-prp)](https://github.com/arthur-r-oliveira/ocp-abi-local-sno/actions/workflows/sno-test-matrix.yml/badge.svg)](https://github.com/arthur-r-oliveira/ocp-abi-local-sno/actions/workflows/sno-test-matrix.yml)

Deploys **Single Node OpenShift** on a KVM/libvirt host via the agent-based
installer, in three topologies selected by one Ansible var - from a plain
baseline SNO up to a real Parallel Redundancy Protocol (PRP, RFC 62439-3)
link built with the kernel's `hsr` driver, either as a side network between
two clusters or as the cluster's *primary* network underneath `br-ex`.

Currently targets **OpenShift 5.0.0-rc.2**.

| Topology (`-e sno_topology=...`) | Nodes | NICs/node | PRP role | Status |
|---|---|---|---|---|
| `single` | 1 | 1 -> `ocp-public` | none - baseline sanity check | **PASS** |
| `dual-sidecar-prp` (default) | 2 independent | 3 -> ocp-public + prp-lan-a + prp-lan-b | side link between two clusters, not in the critical path | **PASS** - 0% loss failover, proven |
| `single-primary-prp` | 1 | 2 -> prp-lan-a + prp-lan-b, `prp0` underlies `br-ex` | load-bearing for cluster networking, not a sidecar | Two separate upstream bugs found and root-caused; the first (`nmstate`) is **worked around** - `prp0` is fully up and functional. The second (`assisted-installer-agent`) still blocks full install completion (see docs) |

```
dual-sidecar-prp (the flagship topology - two clusters, one PRP link between them)

                 ocp-public (NAT) - br-ex / API / Ingress / egress
        ┌───────────────┬───────────────────────┬───────────────┐
        │                                                        │
   ┌────┴────┐                                              ┌────┴────┐
   │  sno-a  │──eth1── prp-lan-a (isolated) ─────────────────│  sno-b  │
   │ 8vCPU/  │──eth2── prp-lan-b (isolated) ─────────────────│ 16GB    │
   │  16GB   │                                               │         │
   └─────────┘                                               └─────────┘
   prp0 = eth1+eth2 (hsr driver, PRP mode)   10.10.10.1 / 10.10.10.2
```

One Ansible playbook, one template set per topology (`vars/topologies/*.yml`,
`templates/vm-definition/*.xml.j2`, `templates/agent-config/*.yaml.j2`) -
nothing copy-pasted per node, and each topology's own vars decide NIC count,
network layout, and which of the Day-0/Day-2 workarounds below apply.

## Start here

- **[docs/installation.md](docs/installation.md)** - architecture, prerequisites,
  configuration, running the playbook, every real gotcha hit deploying this.
- **[docs/prp-test-case.md](docs/prp-test-case.md)** - the PRP mechanism, the
  Day-0 `nmstate` bug that blocks it on a side network, the Day-2 fix via the
  `kubernetes-nmstate-operator`, and a real hypervisor-level failover test.
- **[docs/spec-test-case-3-prp-primary.md](docs/spec-test-case-3-prp-primary.md)** -
  PRP as the *primary* network: the spec, the original Day-0 failure, a
  confirmed working Day-0 workaround (`scripts/embed-day0-file.py`), and a
  second, still-open, distinct blocker found after the first one was fixed.
- **[docs/prp-hackathon-report.html](docs/prp-hackathon-report.html)** - a
  standalone, self-contained visual summary of the Test Case 2 investigation
  (open directly in a browser) - built for sharing outside the repo.
- **[docs/ocp5-install-report.md](docs/ocp5-install-report.md)** - all three
  topologies' results, the host-memory-oversubscription lesson, EL10 gotchas,
  and CI status in one place. Standalone visual counterpart:
  **[docs/ocp5-install-report.html](docs/ocp5-install-report.html)** (open
  directly in a browser) - every report gets a markdown file committed here,
  not just a standalone HTML copy.
- **[docs/upstream-issue-1-nmstate-hsr-gen-conf.md](docs/upstream-issue-1-nmstate-hsr-gen-conf.md)** /
  **[docs/upstream-issue-2-agent-based-installer-hsr.md](docs/upstream-issue-2-agent-based-installer-hsr.md)** /
  **[docs/upstream-issue-3-assisted-installer-agent-hsr-inventory.md](docs/upstream-issue-3-assisted-installer-agent-hsr-inventory.md)** -
  paste-ready draft issues for three separate upstream bugs found chasing
  PRP as the primary network: `nmstate` (interface never comes up at Day-0),
  the Agent-Based Installer tracking issue for that, and
  `assisted-installer-agent` (a working interface is invisible to host
  inventory, blocking install even after the first bug is worked around).
  None filed yet.

## Layout

| Path | What |
|---|---|
| `sno_playbook.yml`, `tasks/deploy_node.yml`, `vars/main.yml` | The Ansible playbook - libvirt networks, VM definitions, ignition/agent-config generation, one loop iteration per node in each topology's `sno_nodes` list |
| `vars/topologies/*.yml` | Per-topology vars: node list, NIC count/roles, network CIDRs, and which workaround flags apply (`topology_needs_day0_extra_manifests`, `topology_needs_prp_nmconnection_workaround`, `topology_needs_serial_console_debug`) |
| `templates/vm-definition/*.xml.j2`, `templates/agent-config/*.yaml.j2` | Per-topology libvirt domain XML and `agent-config.yaml` - one pair per topology, not one file with conditionals throughout |
| `day2-manifests/` | Applied via `oc apply` **after** `install-complete`, once per cluster (dual-sidecar-prp only) - installs `kubernetes-nmstate-operator` and configures `prp0` via `NodeNetworkConfigurationPolicy`. Not part of the ansible run; see docs/prp-test-case.md for why this has to be Day-2 |
| `day0-manifests/` | Delivered before first boot, two different ways for two different needs - see docs/spec-test-case-3-prp-primary.md's "Update" section for why they're not interchangeable: `99-hsr-module-autoload.yaml.j2` is a real Day-0-extra-manifest (MachineConfig, applied Day-1 by MCO once a cluster exists); `prp0.nmconnection.j2` is plain keyfile content merged straight into the ISO's own Ignition config via `scripts/embed-day0-file.py` (applies pre-boot, which extra manifests don't) |
| `scripts/` | `add-cluster-hosts.sh` (per-node `/etc/hosts` entries), `prp-lab-tunnel.sh` (an `sshuttle` tunnel scoped to `ocp-public` only, for reaching the VMs from a workstation that isn't the KVM host), `wipe-all-sno.sh` (destroys/undefines every VM this repo can create, across every topology - a clean slate), `test-single.sh` / `test-prp-failover.sh` (per-topology health/failover checks - see "Testing" below), `run-test-matrix.sh` (the CI entry point: wipe, run Test Case 1, wipe, run Test Case 2, wipe, report), and `embed-day0-file.py` (merges a file into an ISO's real Ignition config - the single-primary-prp workaround's actual mechanism) |
| `.github/workflows/prp-test.yml` | Runs `test-prp-failover.sh` against an **already-deployed** dual-sidecar-prp cluster - an ongoing health check, not a deploy |
| `.github/workflows/sno-test-matrix.yml` | Runs `run-test-matrix.sh`: wipes everything, deploys and tests Test Case 1 and Test Case 2 from scratch, wiping between and after each. Both workflows need a self-hosted runner registered on the KVM host (label `kvm-prp-lab`) - can't run on GitHub's hosted runners, this needs real `virsh`/SSH access to the VMs |
| `docs/` | The real documentation - read this, not this file |

## Quick start

```
ansible-playbook sno_playbook.yml -e sno_topology=<single|dual-sidecar-prp|single-primary-prp>
```
Defaults to `dual-sidecar-prp` if `-e sno_topology=...` is omitted.

For `dual-sidecar-prp`, then per node, once
`openshift-install agent wait-for install-complete` returns:

```
export KUBECONFIG=<install_dir>/auth/kubeconfig
oc apply -f day2-manifests/00-nmstate-catalogsource.yaml
oc apply -f day2-manifests/01-nmstate-operator-subscription.yaml
# wait for: oc get csv -n openshift-nmstate  ->  Succeeded
oc apply -f day2-manifests/02-nmstate-cr.yaml
# wait for: oc get pods -n openshift-nmstate  ->  nmstate-handler Running
oc apply -f day2-manifests/03-nncp-sno-a.yaml   # or 03-nncp-sno-b.yaml
oc apply -f day2-manifests/04-hsr-module-autoload.yaml
```

`single` and `single-primary-prp` need no Day-2 steps - `single` has no PRP
at all, and `single-primary-prp`'s PRP workaround is entirely Day-0 (see
docs/spec-test-case-3-prp-primary.md).

Full details, exact commands, and real output from an actual run: **docs/installation.md**.

## Testing

Per-topology checks, each exits non-zero on any failure:

```
./scripts/test-single.sh          # Test Case 1: cluster health only, no PRP
./scripts/test-prp-failover.sh    # Test Case 2: health + prp0 mode + reachability +
                                   #              a real hypervisor-level failover cut
```

For the full "start from nothing, prove it, clean up" cycle:

```
./scripts/run-test-matrix.sh
```
Wipes every known SNO VM, deploys and tests Test Case 1, wipes, deploys
and tests Test Case 2, wipes again, and writes a markdown report
(default: `/tmp/sno-test-matrix-report.md`). This is what
`.github/workflows/sno-test-matrix.yml` runs in CI - budget a couple of
hours; `openshift-install`'s own internal timeouts alone allow up to
~70 minutes per node.

**Test Case 3 (`single-primary-prp`) is not in this matrix yet** - its
Day-0 network bug now has a confirmed workaround, but a second, distinct
blocker (an `assisted-service` validation issue, not yet root-caused)
still stops it from completing an actual install end to end. See
docs/spec-test-case-3-prp-primary.md before adding it here.

**TNF (Two-Node with Fencing) is not in this matrix yet either** - it needs
its own design pass (a different install flow, a virtual BMC, an external
load balancer) before it can be automated the same way.
