#!/bin/bash
# End-to-end iSCSI test against a portal. Run with sudo (iscsictl needs auth).
#   sudo ./test_nas.sh 192.168.1.100[:3260]  [chap-user chap-secret]
PORTAL="${1:-192.168.1.100:3260}"
[[ "$PORTAL" == *:* ]] || PORTAL="$PORTAL:3260"
CHAP_USER="${2:-}"
CHAP_SECRET="${3:-}"

echo "===================================================================="
echo " iSCSI end-to-end test against $PORTAL"
echo "===================================================================="

echo ">> [1] Enabling SendTargets discovery (interval 30s = minimum)..."
iscsictl modify discovery-config -SendTargets enable -interval 30 2>&1 || true

echo ">> [2] Adding discovery portal $PORTAL ..."
iscsictl add discovery-portal "$PORTAL" 2>&1 || true
# Re-assert discovery config to kick a discovery pass now
iscsictl modify discovery-config -SendTargets enable -interval 30 2>&1 || true

echo ">> [3] Waiting for targets to be discovered (up to ~75s)..."
TGT=""
for i in $(seq 1 25); do
  OUT="$(iscsictl list targets 2>/dev/null)"
  TGT="$(echo "$OUT" | grep -oE 'iqn\.[^ ,]+' | head -1)"
  [ -n "$TGT" ] && break
  sleep 2
done
echo "---- iscsictl list targets ----"
iscsictl list targets 2>&1
echo "-------------------------------"

if [ -z "$TGT" ]; then
  echo "!! No target discovered. The NAS may require the initiator IQN to be"
  echo "   allow-listed, or CHAP auth. Initiator IQN is:"
  iscsictl list initiator-config 2>&1 | grep -i iqn || true
  echo "   Configure the NAS to allow this initiator, then re-run."
  echo "---- recent iscsid log (discovery attempts / errors) ----"
  tail -25 /var/log/iscsid 2>/dev/null || log show --predicate 'process == "iscsid"' --last 3m 2>/dev/null | tail -25
  echo "--------------------------------------------------------"
  exit 1
fi
echo ">> Discovered target: $TGT"

if [ -n "$CHAP_USER" ]; then
  echo ">> [3b] Setting CHAP auth for $TGT ..."
  iscsictl modify target-config "$TGT,$PORTAL" -authentication CHAP \
     -CHAPName "$CHAP_USER" -CHAPSecret "$CHAP_SECRET" 2>&1 || true
fi

echo ">> [4] Logging in to $TGT ..."
iscsictl login "$TGT" 2>&1
sleep 2

echo ">> [5] LUNs exposed:"
iscsictl list luns 2>&1

echo ">> [6] Sessions / targets:"
iscsictl list targets 2>&1

echo ">> [7] Block devices (look for a new /dev/diskN):"
diskutil list 2>&1 | tail -20

echo "===================================================================="
echo " If a new disk appeared above -> the driver works end to end."
echo " Format/mount it in Disk Utility, or:  diskutil eraseDisk APFS iSCSI /dev/diskN"
echo " To log out later:  sudo iscsictl logout $TGT"
echo "===================================================================="
