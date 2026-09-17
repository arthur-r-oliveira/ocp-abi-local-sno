#!/usr/bin/env bash
# Health check for the "single" topology (Test Case 1: one plain SNO,
# no PRP). No failover mechanism to test here - this just confirms the
# cluster actually came up healthy.
#
# All defaults match vars/topologies/single.yml's out-of-the-box values -
# override via env if your deployment customized them.
#
# Exit code 0 = passed, 1 = failed.
#
# Usage: ./test-single.sh

set -uo pipefail

NODE_NAME="${NODE_NAME:-sno-single}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/home/libvirt-images/sno-install/sno-single/auth/kubeconfig}"

PASS=0
FAIL=0

record() {
  local status="$1" name="$2" detail="${3:-}"
  if [ "$status" = "PASS" ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); fi
  printf '[%s] %s%s\n' "$status" "$name" "${detail:+ - $detail}"
}

echo "== Single SNO (no PRP) :: test suite =="
echo "node=$NODE_NAME kubeconfig=$KUBECONFIG_PATH"
echo

if [ ! -r "$KUBECONFIG_PATH" ]; then
  record FAIL "cluster-health:$NODE_NAME" "kubeconfig not readable: $KUBECONFIG_PATH"
else
  avail=$(KUBECONFIG="$KUBECONFIG_PATH" oc get clusterversion version \
    -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null)
  unhealthy=$(KUBECONFIG="$KUBECONFIG_PATH" oc get co --no-headers 2>/dev/null \
    | awk '$3!="True" || $4!="False" || $5!="False" {print $1}')
  node_ready=$(KUBECONFIG="$KUBECONFIG_PATH" oc get node "${NODE_NAME}.apps.lab.corp" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

  if [ "$avail" = "True" ] && [ -z "$unhealthy" ]; then
    record PASS "cluster-health:$NODE_NAME" "ClusterVersion Available, all operators healthy"
  else
    record FAIL "cluster-health:$NODE_NAME" "Available=$avail unhealthy_operators=[$(echo "$unhealthy" | tr '\n' ',')]"
  fi

  if [ "$node_ready" = "True" ]; then
    record PASS "node-ready:$NODE_NAME" "kubelet Ready"
  else
    record FAIL "node-ready:$NODE_NAME" "Ready=${node_ready:-unknown}"
  fi
fi

echo
echo "== Summary: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
