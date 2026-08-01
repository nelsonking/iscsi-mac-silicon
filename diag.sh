#!/bin/bash
# One-shot login diagnostic. Run with sudo.
#   sudo ./diag.sh 192.168.1.100 <target-iqn>
PORTAL="${1:-192.168.1.100}"; PORTAL_IP="${PORTAL%%:*}"
TARGET="${2:-iqn.2010-01.com.example:target0}"

echo "== diag login to $TARGET via $PORTAL_IP:3260 =="

# Monitor for a TCP connection to the NAS while login runs
( for i in $(seq 1 40); do
    if netstat -an 2>/dev/null | grep -q "${PORTAL_IP}.3260"; then
      echo "  [netmon] connection to NAS present:"; netstat -an 2>/dev/null | grep "${PORTAL_IP}.3260"
      break
    fi
    sleep 0.2
  done ) &
MON=$!

echo ">> logging in..."
iscsictl login "$TARGET" 2>&1
LOGIN_RC=$?
echo "   iscsictl rc=$LOGIN_RC"
wait $MON 2>/dev/null

echo ""
echo "=== kernel IOLog (dmesg) iscsi lines ==="
dmesg 2>/dev/null | grep -i iscsi | tail -40 || echo "  (dmesg empty or needs privileges)"

echo ""
echo "=== daemon stderr log (/var/log/iscsid) ==="
tail -40 /var/log/iscsid 2>/dev/null || echo "  (empty)"

echo ""
echo "=== kext IOLog trace (our ISCSIX tag), last 90s ==="
log show --last 90s --info --debug --predicate 'eventMessage CONTAINS "ISCSIX"' 2>/dev/null | grep "ISCSIX" | tail -40
echo "--- (if empty, IOLog not reaching unified log; trying dmesg) ---"
dmesg 2>/dev/null | grep "ISCSIX" | tail -40
echo ""
echo "=== daemon login-failure line ==="
log show --last 90s --info --predicate 'process == "iscsid"' 2>/dev/null | grep -iE "login|fail|error" | tail -15

echo ""
echo "=== current session/target state ==="
iscsictl list targets 2>&1
