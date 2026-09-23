#!/usr/bin/env bash
# Converts [PASS]/[FAIL] test output (from test-prp-failover.sh,
# test-single.sh) into JUnit XML so GitHub Actions can render it
# natively in the job summary.
#
# Usage: ./to-junit-xml.sh <suite-name> < test-output.log > results.xml
#        some-test.sh 2>&1 | tee log.txt | ./to-junit-xml.sh suite > results.xml

set -euo pipefail

SUITE="${1:?Usage: $0 <suite-name>}"

TESTS=0
FAILURES=0
TESTCASES=""

while IFS= read -r line; do
  case "$line" in
    \[PASS\]*)
      name="${line#\[PASS\] }"
      detail=""
      if [[ "$name" == *" - "* ]]; then
        detail="${name#* - }"
        name="${name%% - *}"
      fi
      TESTS=$((TESTS + 1))
      TESTCASES+="    <testcase classname=\"${SUITE}\" name=\"${name}\""
      if [ -n "$detail" ]; then
        TESTCASES+=">"$'\n'
        TESTCASES+="      <system-out><![CDATA[${detail}]]></system-out>"$'\n'
        TESTCASES+="    </testcase>"$'\n'
      else
        TESTCASES+="/>"$'\n'
      fi
      ;;
    \[FAIL\]*)
      name="${line#\[FAIL\] }"
      detail=""
      if [[ "$name" == *" - "* ]]; then
        detail="${name#* - }"
        name="${name%% - *}"
      fi
      TESTS=$((TESTS + 1))
      FAILURES=$((FAILURES + 1))
      TESTCASES+="    <testcase classname=\"${SUITE}\" name=\"${name}\">"$'\n'
      TESTCASES+="      <failure message=\"${name} failed\"><![CDATA[${detail}]]></failure>"$'\n'
      TESTCASES+="    </testcase>"$'\n'
      ;;
  esac
done

cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<testsuites>
  <testsuite name="${SUITE}" tests="${TESTS}" failures="${FAILURES}" errors="0">
${TESTCASES}  </testsuite>
</testsuites>
EOF
