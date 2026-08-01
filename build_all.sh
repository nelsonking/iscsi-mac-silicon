#!/bin/bash
# Build everything: kext (arm64e) + userspace (arm64).
set -euo pipefail
cd "$(dirname "$0")"
./build_kext.sh
./build_user.sh
echo ""
echo "==================================================================="
echo "Build complete. Artifacts in ./build :"
echo "  iSCSIInitiator.kext   (arm64e kernel extension)"
echo "  iSCSI.framework       (arm64 shared framework)"
echo "  iscsid                (arm64 daemon)"
echo "  iscsictl              (arm64 CLI tool)"
echo ""
echo "Next: sudo ./install.sh   (see INSTALL.md for the one-time"
echo "Apple-Silicon security steps you must do in Recovery first)."
echo "==================================================================="
