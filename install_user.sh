#!/bin/bash
# Reinstall ONLY the userspace (framework + iscsid + iscsictl) and restart the
# daemon. Does NOT touch the loaded kext (no unload/reload, no reboot/approval).
set -uo pipefail
cd "$(dirname "$0")"
if [ "$(id -u)" != "0" ]; then echo "run with sudo"; exit 1; fi
PL=/Library/LaunchDaemons/com.github.iscsi-osx.iscsid.plist

echo ">> Installing iSCSI.framework, iscsid, iscsictl..."
rm -rf /Library/Frameworks/iSCSI.framework
cp -R build/iSCSI.framework /Library/Frameworks/
chown -R root:wheel /Library/Frameworks/iSCSI.framework
cp build/iscsid /usr/local/libexec/iscsid
cp build/iscsictl /usr/local/bin/iscsictl
chown root:wheel /usr/local/libexec/iscsid /usr/local/bin/iscsictl
chmod 755 /usr/local/libexec/iscsid /usr/local/bin/iscsictl

echo ">> Restarting iscsid..."
launchctl bootout system "$PL" 2>/dev/null || true
launchctl bootstrap system "$PL" 2>/dev/null || true
launchctl kickstart -k system/com.github.iscsi-osx.iscsid 2>/dev/null || true
sleep 1
pgrep -qf libexec/iscsid && echo "   iscsid running." || echo "   iscsid will start on first use."
echo ">> Done (kext untouched)."
