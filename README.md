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

## Layout

| Path | What |
|---|---|
| `sno_playbook.yml`, `tasks/deploy_node.yml`, `vars/main.yml` | The Ansible playbook - libvirt networks, VM definitions, ignition/agent-config generation, one loop iteration per node in `vars/main.yml`'s `sno_nodes` list |
| `templates/` | Jinja templates for the 3 libvirt networks, the VM domain XML, and the agent-based installer's `install-config.yaml`/`agent-config.yaml` |
| `day2-manifests/` | Applied via `oc apply` **after** `install-complete`, once per cluster - installs `kubernetes-nmstate-operator` and configures `prp0` via `NodeNetworkConfigurationPolicy`. Not part of the ansible run; see docs/prp-test-case.md for why this has to be Day-2 |
| `scripts/` | `add-cluster-hosts.sh` (per-node `/etc/hosts` entries) and `prp-lab-tunnel.sh` (an `sshuttle` tunnel scoped to `ocp-public` only, for reaching the VMs from a workstation that isn't the KVM host) |
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
```

Full details, exact commands, and real output from an actual run: **docs/installation.md**.
