#!/bin/bash
# Build the iSCSI userspace: iSCSI.framework, iscsid (daemon), iscsictl (tool).
# Plain arm64 userland against the macOS SDK (no kernel headers here).
set -euo pipefail
cd "$(dirname "$0")"
SDK="$(xcrun --show-sdk-path)"
ARCH="${ARCH:-arm64}"
BUILD="build"
FWK_DIR="$BUILD/iSCSI.framework"
FWK_INSTALL="/Library/Frameworks/iSCSI.framework/Versions/A/iSCSI"
NAME_PREFIX_D="com.github.iscsi-osx"
APPID="$NAME_PREFIX_D.iSCSIInitiator"

SHARED="Source/User/iSCSI Framework"
DAEMONDIR="Source/User/iscsid"

mkdir -p "$BUILD/uobj"

CC_COMMON=(-arch "$ARCH" -isysroot "$SDK" -x objective-c -fmodules -fobjc-arc
  -mmacosx-version-min=13.0 -O2 -g -Wno-deprecated-declarations
  -I"$SHARED" -I"$DAEMONDIR" -I"Source/Kernel"
  -DCF_PREFERENCES_APP_ID="\"$APPID\""
  -DNAME_PREFIX_U=com_github_iscsi_osx)

FRAMEWORKS=(-framework Foundation -framework CoreFoundation -framework Security
  -framework DiskArbitration -framework IOKit -framework SystemConfiguration)

compile() { # <src> <obj>
  clang "${CC_COMMON[@]}" -c "$1" -o "$2"
  echo "   [cc ] $(basename "$1")"
}

# ---- iSCSI.framework -------------------------------------------------------
# The framework holds the shared library API + the kernel user-client bridge.
FWK_SRCS=(
  "$SHARED/iSCSITypes.c"
  "$SHARED/iSCSIUtils.c"
  "$SHARED/iSCSIDA.c"
  "$SHARED/iSCSIIORegistry.c"
  "$SHARED/iSCSIKeychain.c"
  "$SHARED/iSCSIPreferences.c"
  "$SHARED/iSCSIAuthRights.c"
  "$SHARED/iSCSIDaemonInterface.c"
  "$DAEMONDIR/iSCSIHBAInterface.c"
  "$DAEMONDIR/iSCSIPDUUser.c"
)
echo ">> Compiling iSCSI.framework..."
FWK_OBJS=()
for s in "${FWK_SRCS[@]}"; do
  o="$BUILD/uobj/fwk_$(basename "${s%.*}").o"; compile "$s" "$o"; FWK_OBJS+=("$o")
done
echo ">> Linking iSCSI.framework dylib..."
rm -rf "$FWK_DIR"
mkdir -p "$FWK_DIR/Versions/A/Headers"
clang -arch "$ARCH" -isysroot "$SDK" -dynamiclib \
  -install_name "$FWK_INSTALL" \
  -compatibility_version 1.0 -current_version 1.0 \
  "${FRAMEWORKS[@]}" "${FWK_OBJS[@]}" -o "$FWK_DIR/Versions/A/iSCSI"
cp "$SHARED"/*.h "$FWK_DIR/Versions/A/Headers/" 2>/dev/null || true
( cd "$FWK_DIR/Versions" && ln -sfh A Current )
( cd "$FWK_DIR" && ln -sfh Versions/Current/iSCSI iSCSI && ln -sfh Versions/Current/Headers Headers )
codesign --force --sign - --timestamp=none "$FWK_DIR" 2>/dev/null || true

# ---- iscsid (daemon) -------------------------------------------------------
DAEMON_SRCS=(
  "$DAEMONDIR/iSCSIDaemon.c"
  "$DAEMONDIR/iSCSISession.c"
  "$DAEMONDIR/iSCSISessionManager.c"
  "$DAEMONDIR/iSCSIDiscovery.c"
  "$DAEMONDIR/iSCSIQueryTarget.c"
  "$DAEMONDIR/iSCSIAuth.c"
)
echo ">> Compiling iscsid..."
DAEMON_OBJS=()
for s in "${DAEMON_SRCS[@]}"; do
  o="$BUILD/uobj/d_$(basename "${s%.*}").o"; compile "$s" "$o"; DAEMON_OBJS+=("$o")
done
echo ">> Linking iscsid..."
clang -arch "$ARCH" -isysroot "$SDK" "${FRAMEWORKS[@]}" \
  -F"$BUILD" -framework iSCSI \
  "${DAEMON_OBJS[@]}" -o "$BUILD/iscsid"
codesign --force --sign - "$BUILD/iscsid" 2>/dev/null || true

# ---- iscsictl (tool) -------------------------------------------------------
echo ">> Compiling + linking iscsictl..."
clang "${CC_COMMON[@]}" -c "Source/User/iscsictl/iSCSICtl.m" -o "$BUILD/uobj/iSCSICtl.o"
echo "   [cc ] iSCSICtl.m"
clang -arch "$ARCH" -isysroot "$SDK" "${FRAMEWORKS[@]}" \
  -F"$BUILD" -framework iSCSI \
  "$BUILD/uobj/iSCSICtl.o" -o "$BUILD/iscsictl"
codesign --force --sign - "$BUILD/iscsictl" 2>/dev/null || true

echo ">> Userspace build done:"
echo "   $FWK_DIR"
echo "   $BUILD/iscsid"
echo "   $BUILD/iscsictl"
file "$BUILD/iscsid" "$BUILD/iscsictl"
