# ocp-abi-local-sno

Deploys **two independent Single Node OpenShift clusters** (`sno-a`, `sno-b`) on a
single KVM/libvirt host via the agent-based installer, cross-connected over two
isolated networks carrying a real Parallel Redundancy Protocol (PRP, RFC 62439-3)
link between them - built with the kernel's `hsr` driver.

Currently targets **OpenShift 5.0.0-rc.2**.

```
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

3 vNICs per node: one dedicated to `ocp-public` (br-ex/API/Ingress/egress),
two dedicated to PRP - nothing shared between roles.

## Start here

- **[docs/installation.md](docs/installation.md)** - architecture, prerequisites,
  configuration, running the playbook, every real gotcha hit deploying this.
- **[docs/prp-test-case.md](docs/prp-test-case.md)** - the PRP mechanism, the
  installer bug that blocks it at Day-0, the Day-2 fix via the
  `kubernetes-nmstate-operator`, and a real hypervisor-level failover test.
- **[docs/prp-hackathon-report.html](docs/prp-hackathon-report.html)** - a
  standalone, self-contained visual summary of the above (open directly in a
  browser) - built for sharing outside the repo.

## Layout

| Path | What |
|---|---|
| `sno_playbook.yml`, `tasks/deploy_node.yml`, `vars/main.yml` | The Ansible playbook - libvirt networks, VM definitions, ignition/agent-config generation, one loop iteration per node in `vars/main.yml`'s `sno_nodes` list |
| `templates/` | Jinja templates for the 3 libvirt networks, the VM domain XML, and the agent-based installer's `install-config.yaml`/`agent-config.yaml` |
| `day2-manifests/` | Applied via `oc apply` **after** `install-complete`, once per cluster - installs `kubernetes-nmstate-operator` and configures `prp0` via `NodeNetworkConfigurationPolicy`. Not part of the ansible run; see docs/prp-test-case.md for why this has to be Day-2 |
| `scripts/` | `add-cluster-hosts.sh` (per-node `/etc/hosts` entries), `prp-lab-tunnel.sh` (an `sshuttle` tunnel scoped to `ocp-public` only, for reaching the VMs from a workstation that isn't the KVM host), `wipe-all-sno.sh` (destroys/undefines every VM this repo can create, across every topology - a clean slate), `test-single.sh` / `test-prp-failover.sh` (per-topology health/failover checks - see "Testing" below), and `run-test-matrix.sh` (the CI entry point: wipe, run Test Case 1, wipe, run Test Case 2, wipe, report) |
| `.github/workflows/prp-test.yml` | Runs `test-prp-failover.sh` against an **already-deployed** dual-sidecar-prp cluster - an ongoing health check, not a deploy |
| `.github/workflows/sno-test-matrix.yml` | Runs `run-test-matrix.sh`: wipes everything, deploys and tests Test Case 1 and Test Case 2 from scratch, wiping between and after each. Both workflows need a self-hosted runner registered on the KVM host (label `kvm-prp-lab`) - can't run on GitHub's hosted runners, this needs real `virsh`/SSH access to the VMs |
| `docs/` | The real documentation - read this, not this file |

## Quick start

```
ansible-playbook sno_playbook.yml
```

then, per node, once `openshift-install agent wait-for install-complete` returns:

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

**TNF (Two-Node with Fencing) is not in this matrix yet** - it needs its
own design pass (a different install flow, a virtual BMC, an external
load balancer) before it can be automated the same way.
