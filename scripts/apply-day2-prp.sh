#!/usr/bin/env bash
# Applies the Day-2 NMState operator + PRP NNCP configuration to both
# sno-a and sno-b after a fresh dual-sidecar-prp install. This is the
# missing link between "install-complete" and "PRP failover test" — the
# agent-based installer cannot create prp0 at Day-0 due to an upstream
# nmstate bug (see docs/upstream-issue-1-nmstate-hsr-gen-conf.md).
#
# Sequence:
#   1. CatalogSource (4.22 index workaround for OCP 5.0 pre-GA)
#   2. Namespace + OperatorGroup + Subscription
#   3. Wait for CSV
#   4. NMState CR (triggers handler DaemonSet)
#   5. Wait for handler pods
#   6. MachineConfig for hsr module autoload (both nodes)
#   7. NNCPs (per-node, per-kubeconfig)
#   8. Wait for prp0 on both nodes
#
# Usage: ./apply-day2-prp.sh

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

KUBECONFIG_A="${KUBECONFIG_A:-/home/libvirt-images/sno-install/sno-a/auth/kubeconfig}"
KUBECONFIG_B="${KUBECONFIG_B:-/home/libvirt-images/sno-install/sno-b/auth/kubeconfig}"
NODE_A_IP="${NODE_A_IP:-192.168.130.101}"
NODE_B_IP="${NODE_B_IP:-192.168.130.102}"
SSH_USER="${SSH_USER:-core}"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -o BatchMode=yes)

FAIL=0

wait_for() {
  local desc="$1" timeout="$2" cmd="$3"
  echo "  Waiting up to ${timeout}s for ${desc}..."
  local elapsed=0
  while [ $elapsed -lt "$timeout" ]; do
    if eval "$cmd" >/dev/null 2>&1; then
      echo "  ${desc}: ready (${elapsed}s)"
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
  done
  echo "  ERROR: ${desc} not ready after ${timeout}s"
  return 1
}

echo "== Day-2 PRP configuration =="
echo "sno-a kubeconfig: $KUBECONFIG_A"
echo "sno-b kubeconfig: $KUBECONFIG_B"
echo

# Both clusters get the same operator infrastructure, so apply to both
for pair in "sno-a:$KUBECONFIG_A" "sno-b:$KUBECONFIG_B"; do
  name="${pair%%:*}"
  kc="${pair#*:}"
  echo "--- ${name}: installing NMState operator ---"

  # 1. CatalogSource (pruned index from the local mirror registry —
  # contains only kubernetes-nmstate-operator, so the gRPC cache builds
  # in seconds instead of the 10-20 minutes the full v4.22 index took).
  KUBECONFIG="$kc" oc apply -f day2-manifests/00-nmstate-catalogsource.yaml
  echo "  Applied CatalogSource (pruned 4.22 index from mirror)"

  # 2. Wait for the catalog pod to become Ready. With the pruned index
  # from the local mirror, this should take ~30-60s instead of 10-20min.
  if ! wait_for "${name} catalog pod Ready" 300 \
    "KUBECONFIG='$kc' oc get pod -n openshift-marketplace -l olm.catalogSource=redhat-operators-4-22 -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null | grep -q true"; then
    echo "  WARNING: catalog pod not ready yet, continuing anyway (OLM may still resolve)"
  fi

  # 3. Namespace + OperatorGroup + Subscription
  KUBECONFIG="$kc" oc apply -f day2-manifests/01-nmstate-operator-subscription.yaml
  echo "  Applied Subscription"

  # 4. Wait for CSV
  if ! wait_for "${name} CSV Succeeded" 600 \
    "KUBECONFIG='$kc' oc get csv -n openshift-nmstate -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Succeeded"; then
    FAIL=1
    continue
  fi

  # 5. NMState CR
  KUBECONFIG="$kc" oc apply -f day2-manifests/02-nmstate-cr.yaml
  echo "  Applied NMState CR"

  # 6. Wait for handler DaemonSet
  if ! wait_for "${name} nmstate-handler ready" 180 \
    "KUBECONFIG='$kc' oc get ds -n openshift-nmstate nmstate-handler -o jsonpath='{.status.numberReady}' 2>/dev/null | grep -qE '^[1-9]'"; then
    FAIL=1
    continue
  fi

  # 7. MachineConfig for hsr module autoload
  KUBECONFIG="$kc" oc apply -f day2-manifests/04-hsr-module-autoload.yaml
  echo "  Applied hsr module autoload MachineConfig"
  echo
done

if [ "$FAIL" -ne 0 ]; then
  echo "ERROR: operator installation failed on one or both nodes, skipping NNCP application"
  exit 1
fi

# 7. Apply NNCPs — each node's NNCP goes to its own cluster
echo "--- Applying NNCPs ---"
KUBECONFIG="$KUBECONFIG_A" oc apply -f day2-manifests/03-nncp-sno-a.yaml
echo "  Applied NNCP to sno-a"
KUBECONFIG="$KUBECONFIG_B" oc apply -f day2-manifests/03-nncp-sno-b.yaml
echo "  Applied NNCP to sno-b"
echo

# Wait for any MachineConfig-triggered reboots to complete before
# checking NNCPs. The hsr module autoload MachineConfig causes MCO to
# reboot each node; if we check too early, the API or SSH may be down.
echo "--- Waiting for MachineConfig rollout (node reboots) ---"
for pair in "sno-a:$KUBECONFIG_A" "sno-b:$KUBECONFIG_B"; do
  name="${pair%%:*}"
  kc="${pair#*:}"
  if ! wait_for "${name} MachineConfigPool updated" 600 \
    "KUBECONFIG='$kc' oc get mcp master -o jsonpath='{.status.conditions[?(@.type==\"Updated\")].status}' 2>/dev/null | grep -q True"; then
    echo "  WARNING: ${name} MCP not yet Updated, continuing"
  fi
done
echo

# 9. Wait for NNCPs to be Available
for pair in "sno-a:$KUBECONFIG_A" "sno-b:$KUBECONFIG_B"; do
  name="${pair%%:*}"
  kc="${pair#*:}"
  if ! wait_for "${name} NNCP Available" 300 \
    "KUBECONFIG='$kc' oc get nncp prp0-hsr -o jsonpath='{.status.conditions[?(@.type==\"Available\")].status}' 2>/dev/null | grep -q True"; then
    FAIL=1
  fi
done

# 9. Verify prp0 is actually up on both nodes via SSH
echo
echo "--- Verifying prp0 on nodes ---"
for pair in "sno-a:$NODE_A_IP" "sno-b:$NODE_B_IP"; do
  name="${pair%%:*}"
  ip="${pair#*:}"
  if ! wait_for "${name} prp0 link up" 120 \
    "ssh ${SSH_OPTS[*]} ${SSH_USER}@${ip} 'ip -br link show prp0 2>/dev/null | grep -q UP'"; then
    FAIL=1
  else
    proto=$(ssh "${SSH_OPTS[@]}" "$SSH_USER@$ip" "ip -d link show prp0 2>/dev/null" \
      | grep -o 'proto [0-9]' | awk '{print $2}')
    echo "  ${name} prp0 proto=${proto} (1=PRP, 0=HSR)"
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then
  echo "== Day-2 PRP configuration complete, prp0 is up on both nodes =="
else
  echo "== Day-2 PRP configuration finished with errors =="
fi
exit $FAIL
