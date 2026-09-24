#!/usr/bin/env bash
# CI entry point: wipes, then runs Test Case 1 (single) and Test Case 2
# (dual-sidecar-prp) back to back, wiping between and after each, and
# writes a markdown report. Meant to be invoked by
# .github/workflows/sno-test-matrix.yml on a self-hosted runner with
# virsh/SSH access to this KVM host - see docs/installation.md.
#
# TNF (Two-Node with Fencing) is intentionally NOT part of this matrix
# yet - see docs/spec-test-case-3-prp-primary.md's sibling spec for why
# (it needs its own design pass: a different install flow, a virtual
# BMC, an external load balancer - not just another -e sno_topology=...
# value).
#
# Exit code 0 = every phase passed, 1 = at least one failed. Always
# finishes by wiping, even on failure, so a failed run doesn't leave the
# host occupied for the next one.
#
# Usage: ./run-test-matrix.sh [report-output-path]

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

REPORT_PATH="${1:-/tmp/sno-test-matrix-report.md}"
LOG_DIR="${LOG_DIR:-/tmp/sno-test-matrix-logs}"
mkdir -p "$LOG_DIR"

STORAGE_BASE="${SNO_STORAGE_BASE:-/home/libvirt-images}"
OVERALL_FAIL=0

REPORT_BODY=""
append_report() { REPORT_BODY+="$1"$'\n'; }

run_logged() {
  # run_logged <log-file> <description> -- <command...>
  local logfile="$1" desc="$2"
  shift 2
  echo "---- $desc ----"
  script -qec "$*" "$logfile"
  local rc=$?
  echo "---- $desc: exit $rc ----"
  return $rc
}

phase_result() {
  local name="$1" rc="$2"
  if [ "$rc" -eq 0 ]; then
    append_report "- **$name**: PASS"
  else
    append_report "- **$name**: FAIL (exit $rc)"
    OVERALL_FAIL=1
  fi
}

append_report "# SNO Test Matrix Report"
append_report ""
append_report "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
append_report "Host: $(hostname)"
append_report ""

# =========================================================================
echo "############ Wipe (pre-matrix) ############"
./scripts/wipe-all-sno.sh
echo

# =========================================================================
echo "############ Test Case 1: single ############"
append_report "## Test Case 1: single"
append_report ""

run_logged "$LOG_DIR/deploy-single.log" "Deploy (single)" \
  ansible-playbook sno_playbook.yml -e sno_topology=single
phase_result "Deploy" $?

if [ -d "${STORAGE_BASE}/sno-install/sno-single" ]; then
  run_logged "$LOG_DIR/install-single.log" "Wait for install-complete (sno-single)" \
    timeout 5400 openshift-install agent wait-for install-complete \
      --dir="${STORAGE_BASE}/sno-install/sno-single" --log-level=info
  phase_result "Install (bootstrap + operators)" $?

  run_logged "$LOG_DIR/test-single.log" "Health check (sno-single)" \
    ./scripts/test-single.sh
  phase_result "Health check" $?
else
  append_report "- **Install**: FAIL (deploy did not produce an install directory)"
  OVERALL_FAIL=1
fi

echo
echo "############ Wipe (between Test Case 1 and 2) ############"
./scripts/wipe-all-sno.sh
echo

append_report ""

# =========================================================================
echo "############ Test Case 2: dual-sidecar-prp ############"
append_report "## Test Case 2: dual-sidecar-prp"
append_report ""

run_logged "$LOG_DIR/deploy-dual.log" "Deploy (dual-sidecar-prp)" \
  ansible-playbook sno_playbook.yml -e sno_topology=dual-sidecar-prp
phase_result "Deploy" $?

# Both nodes bootstrap independently - wait for them in parallel rather
# than doubling the wall-clock time waiting sequentially.
if [ -d "${STORAGE_BASE}/sno-install/sno-a" ] && [ -d "${STORAGE_BASE}/sno-install/sno-b" ]; then
  timeout 5400 openshift-install agent wait-for install-complete \
    --dir="${STORAGE_BASE}/sno-install/sno-a" --log-level=info \
    > "$LOG_DIR/install-sno-a.log" 2>&1 &
  PID_A=$!
  timeout 5400 openshift-install agent wait-for install-complete \
    --dir="${STORAGE_BASE}/sno-install/sno-b" --log-level=info \
    > "$LOG_DIR/install-sno-b.log" 2>&1 &
  PID_B=$!

  wait "$PID_A"; RC_A=$?
  wait "$PID_B"; RC_B=$?
  phase_result "Install sno-a (bootstrap + operators)" $RC_A
  phase_result "Install sno-b (bootstrap + operators)" $RC_B

  if [ "$RC_A" -eq 0 ] && [ "$RC_B" -eq 0 ]; then
    run_logged "$LOG_DIR/day2-prp.log" "Day-2 PRP configuration (NMState operator + NNCPs)" \
      ./scripts/apply-day2-prp.sh
    phase_result "Day-2 PRP configuration" $?
  else
    append_report "- **Day-2 PRP configuration**: SKIP (install failed)"
  fi

  run_logged "$LOG_DIR/test-prp-failover.log" "PRP failover suite" \
    ./scripts/test-prp-failover.sh
  phase_result "PRP failover suite (health, prp0 mode, reachability, failover, node_table)" $?
else
  append_report "- **Install**: FAIL (deploy did not produce install directories)"
  OVERALL_FAIL=1
fi

echo
echo "############ Post-matrix ############"
echo "Skipping post-matrix wipe: leaving the last topology (dual-sidecar-prp)"
echo "running for downstream pipelines (e.g. must-gather-operator)."
echo

append_report ""
append_report "## Overall"
append_report ""
if [ "$OVERALL_FAIL" -eq 0 ]; then
  append_report "**PASS** - every phase above passed."
else
  append_report "**FAIL** - see the phases marked FAIL above. Full logs: \`$LOG_DIR\`."
fi

printf '%s' "$REPORT_BODY" > "$REPORT_PATH"
echo
echo "Report written to $REPORT_PATH"

# Surface in the GitHub Actions run summary too, when running there.
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s' "$REPORT_BODY" >> "$GITHUB_STEP_SUMMARY"
fi

exit "$OVERALL_FAIL"
