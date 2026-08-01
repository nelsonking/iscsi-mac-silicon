# iSCSI Initiator for modern macOS (Apple Silicon) — Build & Install

A revival of the [iscsi-osx/iSCSIInitiator](https://github.com/iscsi-osx/iSCSIInitiator)
project, ported to build and run on macOS 26/27 on Apple Silicon (arm64e kext +
arm64 userland) using **only the Command Line Tools** — no full Xcode, no KDK.

## What you get
- `iSCSIInitiator.kext` — the virtual SCSI HBA (arm64e). It opens the TCP
  connection to the target in-kernel and presents the remote LUNs as real
  `/dev/diskN` block devices (Disk Utility, partitioning, etc. all work).
- `iSCSI.framework`, `iscsid` (daemon), `iscsictl` (command-line control).

## Build
```
./build_all.sh
```
Artifacts land in `./build`.

## Install (Apple Silicon — one-time security setup required)

Loading **any** third-party kext on Apple Silicon (this one, or commercial ones
like Daemon Tools' iSCSI add-on) requires lowering the boot security policy.
This is a one-time action.

### Step 1 — Reduce security in Recovery (once)
1. Shut down the Mac.
2. Press and **hold the power button** until "Loading startup options" appears.
3. Click **Options > Continue** to enter Recovery.
4. Menu bar: **Utilities > Startup Security Utility**.
5. Select your system disk, click **Security Policy…**
6. Choose **Reduced Security**, and tick
   **"Allow user management of kernel extensions from identified developers"**.
7. OK, then reboot into macOS.

### Step 2 — Install
```
sudo ./install.sh
```
The first run copies everything into place and tries to load the kext. On the
first attempt macOS will **block** it and show a prompt.

### Step 3 — Approve the kext
1. Open **System Settings > General > Login Items & Extensions**
   (older layout: **Privacy & Security**, scroll to the bottom).
2. Find the blocked "iSCSIInitiator" item, click **Allow / Enable**,
   authenticate.
3. **Reboot** when prompted (this rebuilds the auxiliary kernel collection).

### Step 4 — Finish install
```
sudo ./install.sh      # run again; the kext now loads
```

## Use
```
# add a target and log in
iscsictl add target iqn.2010-01.com.example:target0,192.168.1.100:3260
iscsictl login iqn.2010-01.com.example:target0

# see connected LUNs / disks
iscsictl list targets
iscsictl list luns
diskutil list
```
Once logged in, the LUN appears as a normal disk — format/mount it in Disk
Utility as usual.

## Uninstall
```
sudo ./uninstall.sh
```

## Notes
- CHAP (one-way and mutual) auth is supported: `iscsictl modify target-config …`.
- Header/Data digests use CRC32C; on arm64 a portable software implementation
  is used (verified against the standard `0xE3069283` check vector).
- To revert the security policy later, repeat Step 1 and choose Full Security
  (do this only after uninstalling and rebooting).
