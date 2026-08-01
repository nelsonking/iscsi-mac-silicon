#!/bin/bash
# Install the iSCSI initiator (kext + framework + daemon + tool).
# Must be run with sudo. Assumes ./build_kext.sh and ./build_user.sh have run.
set -euo pipefail
cd "$(dirname "$0")"

if [ "$(id -u)" != "0" ]; then echo "Please run with sudo: sudo ./install.sh"; exit 1; fi

BUILD="build"
KEXT_SRC="$BUILD/iSCSIInitiator.kext"
FWK_SRC="$BUILD/iSCSI.framework"
DAEMON_SRC="$BUILD/iscsid"
CTL_SRC="$BUILD/iscsictl"
PLIST_SRC="Source/User/iscsid/com.github.iscsi-osx.iscsid.plist"

for f in "$KEXT_SRC" "$FWK_SRC" "$DAEMON_SRC" "$CTL_SRC"; do
  [ -e "$f" ] || { echo "Missing build artifact: $f  (run ./build_kext.sh && ./build_user.sh)"; exit 1; }
done

echo ">> Installing iSCSI.framework -> /Library/Frameworks/"
rm -rf /Library/Frameworks/iSCSI.framework
cp -R "$FWK_SRC" /Library/Frameworks/
chown -R root:wheel /Library/Frameworks/iSCSI.framework

echo ">> Installing iscsid -> /usr/local/libexec/  and iscsictl -> /usr/local/bin/"
mkdir -p /usr/local/libexec /usr/local/bin
cp "$DAEMON_SRC" /usr/local/libexec/iscsid
cp "$CTL_SRC"   /usr/local/bin/iscsictl
chown root:wheel /usr/local/libexec/iscsid /usr/local/bin/iscsictl
chmod 755 /usr/local/libexec/iscsid /usr/local/bin/iscsictl

echo ">> Installing launchd daemon plist -> /Library/LaunchDaemons/"
cp "$PLIST_SRC" /Library/LaunchDaemons/com.github.iscsi-osx.iscsid.plist
chown root:wheel /Library/LaunchDaemons/com.github.iscsi-osx.iscsid.plist
chmod 644 /Library/LaunchDaemons/com.github.iscsi-osx.iscsid.plist

echo ">> Installing kext -> /Library/Extensions/"
rm -rf /Library/Extensions/iSCSIInitiator.kext
cp -R "$KEXT_SRC" /Library/Extensions/
chown -R root:wheel /Library/Extensions/iSCSIInitiator.kext

echo ">> Registering / loading kext (kmutil load)..."
PL=/Library/LaunchDaemons/com.github.iscsi-osx.iscsid.plist
# Stop the daemon first so it releases its user-client handle on the kext.
launchctl bootout system "$PL" 2>/dev/null || true
# If a previous build is already loaded, unload it so the rebuilt kext takes
# effect. If unload fails (kext busy), keep going: the new kext is staged in
# /Library/Extensions and will load on the next reboot. We still (re)start the
# daemon below so the system never gets left with iscsid down.
UNLOAD_WARN=""
if kmutil showloaded 2>/dev/null | grep -q "com.github.iscsi-osx.iSCSIInitiator"; then
  echo "   unloading previously-loaded kext..."
  if ! kmutil unload -b com.github.iscsi-osx.iSCSIInitiator 2>&1; then
    UNLOAD_WARN="yes"
    echo "   !! could not unload the running kext (a session may be lingering)."
    echo "      The new kext is staged; REBOOT to activate it. Continuing to (re)start iscsid."
  fi
fi
LOAD_OK=0
if kmutil showloaded 2>/dev/null | grep -q "com.github.iscsi-osx.iSCSIInitiator"; then
  echo "   kext still loaded (unload failed); skipping load."
  LOAD_OK=1
elif kmutil load -p /Library/Extensions/iSCSIInitiator.kext 2>&1; then
  echo "   kext loaded."
  LOAD_OK=1
fi

# Always (re)start the daemon, regardless of kext (un)load outcome.
echo ">> (Re)starting iscsid via launchd..."
launchctl bootstrap system "$PL" 2>/dev/null || true
launchctl kickstart -k system/com.github.iscsi-osx.iscsid 2>/dev/null || true
sleep 1
if pgrep -qf "libexec/iscsid"; then echo "   iscsid is running."; else
  echo "   NOTE: iscsid not resident yet; it will start on first iscsictl use."; fi

if [ "$LOAD_OK" = 1 ]; then
  [ -n "$UNLOAD_WARN" ] && echo "   (running the OLD kext until you reboot)"
  echo ""
  echo "=== Installed. Verify with:  iscsictl list targets ==="
else
  cat <<'EOF'

------------------------------------------------------------------
The kext could not be loaded yet. On Apple Silicon this is expected
the FIRST time. Do the following, then re-run  sudo ./install.sh :

1. Open  System Settings > General > Login Items & Extensions
   (or Privacy & Security). You should see a prompt that system
   software "iSCSIInitiator" / an identified developer was blocked.
   Click "Allow", authenticate, and REBOOT when asked.

   If you have NOT yet lowered the security policy, first:
     - Shut down. Hold the power button to enter Recovery.
     - Utilities > Startup Security Utility > select your disk >
       "Reduced Security" + "Allow user management of kernel
       extensions from identified developers". Reboot.

2. After the reboot, run:  sudo ./install.sh   again.
------------------------------------------------------------------
EOF
fi
