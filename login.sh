#!/bin/bash
# Statically add a target (no discovery) and log in through our driver.
#   sudo ./login.sh <portal> <target-iqn> [chap-user chap-secret]
set -uo pipefail
PORTAL="${1:?usage: sudo ./login.sh <portal> <target-iqn> [chap-user chap-secret]}"
TARGET="${2:?target IQN required}"
[[ "$PORTAL" == *:* ]] || PORTAL="$PORTAL:3260"
CHAP_USER="${3:-}"; CHAP_SECRET="${4:-}"

echo "== Target: $TARGET  via $PORTAL =="

# Disable SendTargets discovery and drop any leftover discovery portal. The
# discovery worker has a separate (known) crash bug; with static login we do not
# need discovery at all, and a crashing discovery thread would take the daemon
# down mid-login and surface as EIO.
PORTAL_IP="${PORTAL%%:*}"
echo ">> [0] Disabling discovery (not needed for static login)..."
iscsictl modify discovery-config -SendTargets disable 2>&1 || true
iscsictl remove discovery-portal "$PORTAL_IP" 2>&1 || true

echo ">> [1] Adding target (static)..."
iscsictl add target "$TARGET,$PORTAL" 2>&1 || true

if [ -n "$CHAP_USER" ]; then
  echo ">> [1b] Configuring CHAP..."
  iscsictl modify target-config "$TARGET,$PORTAL" -authentication CHAP \
     -CHAPName "$CHAP_USER" -CHAPSecret "$CHAP_SECRET" 2>&1 || true
fi

echo ">> [2] Logging in..."
iscsictl login "$TARGET" 2>&1

echo ">> [3] Waiting for LUN to attach..."
for i in $(seq 1 10); do
  iscsictl list luns 2>/dev/null | grep -qiE "disk|lun|iqn" && break
  sleep 1
done

echo "---- iscsictl list targets ----"; iscsictl list targets 2>&1
echo "---- iscsictl list luns ----";    iscsictl list luns 2>&1
echo "---- new block devices ----";     diskutil list 2>&1 | tail -25
echo "---- kernel (kext) log from this attempt (needs DEBUG kext) ----"
log show --last 90s --predicate 'process == "kernel" AND eventMessage CONTAINS[c] "iscsi"' 2>/dev/null | tail -50

echo ""
echo "If a new /dev/diskN appeared -> END TO END SUCCESS."
echo "Format it:   diskutil eraseDisk APFS iSCSI /dev/diskN   (replace N)"
echo "Log out:     sudo iscsictl logout $TARGET"
