#!/usr/bin/env bash
# Adds /etc/hosts entries so the sno-a / sno-b API and console routes
# resolve from THIS machine. /etc/hosts has no wildcard support, so
# every route hostname actually needed (console/downloads/oauth) is
# listed explicitly rather than "*.apps...".
#
# Idempotent: re-running replaces the previous block instead of
# duplicating it. Requires root (writes /etc/hosts).
#
# Usage: sudo ./add-cluster-hosts.sh

set -euo pipefail

HOSTS_FILE="/etc/hosts"
MARKER_BEGIN="# BEGIN ocp-abi-local-sno PRP clusters"
MARKER_END="# END ocp-abi-local-sno PRP clusters"

# Adjust these if node IPs/hostnames/domain change (see vars/main.yml).
SNO_A_IP="192.168.130.101"
SNO_A_HOSTNAME="sno-a"
SNO_B_IP="192.168.130.102"
SNO_B_HOSTNAME="sno-b"
SNO_DOMAIN="apps.lab.corp"

if [[ $EUID -ne 0 ]]; then
  echo "Must run as root (writes ${HOSTS_FILE})." >&2
  exit 1
fi

entries_for() {
  local ip="$1" hostname="$2"
  echo "${ip} api.${hostname}.${SNO_DOMAIN} console-openshift-console.apps.${hostname}.${SNO_DOMAIN} downloads-openshift-console.apps.${hostname}.${SNO_DOMAIN} oauth-openshift.apps.${hostname}.${SNO_DOMAIN}"
}

cp "${HOSTS_FILE}" "${HOSTS_FILE}.bak.$(date +%Y%m%d%H%M%S)"

# Strip any previous block this script added, and any older manual
# entries for these two hostnames, before re-appending fresh ones.
sed -i "/${MARKER_BEGIN}/,/${MARKER_END}/d" "${HOSTS_FILE}"
sed -i "/\bapi\.${SNO_A_HOSTNAME}\.${SNO_DOMAIN//./\\.}\b/d; /\bapi\.${SNO_B_HOSTNAME}\.${SNO_DOMAIN//./\\.}\b/d" "${HOSTS_FILE}"

{
  echo "${MARKER_BEGIN}"
  entries_for "${SNO_A_IP}" "${SNO_A_HOSTNAME}"
  entries_for "${SNO_B_IP}" "${SNO_B_HOSTNAME}"
  echo "${MARKER_END}"
} >> "${HOSTS_FILE}"

echo "Updated ${HOSTS_FILE} (backup saved alongside it)."
grep -A3 "${MARKER_BEGIN}" "${HOSTS_FILE}"
