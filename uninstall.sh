#!/bin/bash
# Remove the iSCSI initiator. Log out of all targets first.
set -uo pipefail
cd "$(dirname "$0")"
if [ "$(id -u)" != "0" ]; then echo "Please run with sudo: sudo ./uninstall.sh"; exit 1; fi

echo ">> Stopping iscsid..."
launchctl unload -w /Library/LaunchDaemons/com.github.iscsi-osx.iscsid.plist 2>/dev/null || true

echo ">> Unloading kext..."
kmutil unload -b com.github.iscsi-osx.iSCSIInitiator 2>/dev/null || true

echo ">> Removing files..."
rm -f  /Library/LaunchDaemons/com.github.iscsi-osx.iscsid.plist
rm -rf /Library/Extensions/iSCSIInitiator.kext
rm -rf /Library/Frameworks/iSCSI.framework
rm -f  /usr/local/libexec/iscsid
rm -f  /usr/local/bin/iscsictl

echo ">> Done. A reboot is recommended to fully unload the kext from the"
echo "   auxiliary kernel collection."
