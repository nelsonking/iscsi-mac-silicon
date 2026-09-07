import Foundation
import IOKit

/// Locates the BSD disk (e.g. "disk4") backing a given iSCSI target by walking
/// the IORegistry. This mirrors the kernel/daemon-side logic in
/// `iSCSIIORegistryGetTargetEntry` + `iSCSIIORegistryIOMediaApplyFunction`
/// (Source/User/iSCSI Framework/iSCSIIORegistry.c) so the App can bind a disk
/// to a specific target IQN instead of grabbing the first iSCSI disk it sees.
///
/// Without this, `ISCSIController.findDisk(for:)` returned the same disk for
/// every target, so `diskutil unmountDisk force` on disconnect/unmount hit the
/// wrong target's volume — removing one target appeared to remove them all.
enum IOKitDiskFinder {

    /// IORegistry class name of the iSCSI virtual HBA. Built from
    /// `NAME_PREFIX_U` (`com_github_iscsi_osx`) + `iSCSIVirtualHBA` — see
    /// Source/Kernel/iSCSIKernelClasses.h and build_user.sh.
    private static let hbaClassName = "com_github_iscsi_osx_iSCSIVirtualHBA"

    /// Property keys (see iSCSIIORegistry.h and IOStorage headers).
    private static let protocolCharacteristicsKey = "Protocol Characteristics"
    private static let iSCSIQualifiedNameKey     = "iSCSI Qualified Name"
    private static let bsdNameKey                = "BSD Name"
    private static let blockStorageDriverClass   = "IOBlockStorageDriver"

    /// Returns the BSD device identifier (e.g. "disk4") for the whole-disk
    /// IOMedia backing `iqn`, or `nil` if the target has no attached LUN yet.
    static func findDiskForIQN(_ iqn: String) -> String? {
        guard !iqn.isEmpty else { return nil }

        let matching = IOServiceMatching(hbaClassName)
        let hba = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard hba != 0 else { return nil }
        defer { IOObjectRelease(hba) }

        var targetIter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(hba, kIOServicePlane, &targetIter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(targetIter) }

        // The HBA's children are the iSCSI target entries (one per session).
        // Find the one whose "Protocol Characteristics" dict carries our IQN.
        var targetEntry = IOIteratorNext(targetIter)
        while targetEntry != 0 {
            if let raw = IORegistryEntryCreateCFProperty(
                targetEntry, protocolCharacteristicsKey as CFString,
                kCFAllocatorDefault, 0)?.takeRetainedValue(),
               let proto = raw as? [String: Any],
               let entryIQN = proto[iSCSIQualifiedNameKey] as? String,
               entryIQN == iqn
            {
                let bsd = findWholeDiskBSDName(in: targetEntry)
                IOObjectRelease(targetEntry)
                return bsd
            }
            IOObjectRelease(targetEntry)
            targetEntry = IOIteratorNext(targetIter)
        }
        return nil
    }

    /// Recursively walks the subtree rooted at `targetEntry` looking for an
    /// `IOBlockStorageDriver` node; the whole-disk IOMedia is its first child.
    /// Mirrors `iSCSIIORegistryIOMediaApplyFunction` (iSCSIIORegistry.c:156).
    private static func findWholeDiskBSDName(in root: io_object_t) -> String? {
        var iter: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(root, kIOServicePlane, &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }

        var entry = IOIteratorNext(iter)
        while entry != 0 {
            // Recurse first so we descend into every branch of the tree.
            if let bsd = findWholeDiskBSDName(in: entry) {
                IOObjectRelease(entry)
                return bsd
            }

            // An IOBlockStorageDriver's first child is the whole-disk IOMedia.
            if let cls = IOObjectCopyClass(entry)?.takeRetainedValue() as String?,
               cls == blockStorageDriverClass
            {
                var child: io_object_t = 0
                if IORegistryEntryGetChildEntry(entry, kIOServicePlane, &child) == KERN_SUCCESS,
                   child != 0
                {
                    let bsd = IORegistryEntryCreateCFProperty(
                        child, bsdNameKey as CFString,
                        kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                    IOObjectRelease(child)
                    if let bsd = bsd, !bsd.isEmpty {
                        IOObjectRelease(entry)
                        return bsd
                    }
                }
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iter)
        }
        return nil
    }

    /// Reads cumulative read/write byte counts from the SCSI layer's
    /// `Device Stats` (held by `AppleSCSISubsystemGlobals`). The counters are
    /// block counts, multiplied by the logical block size (512 for this
    /// initiator's targets). Returns nil if the stats node is unavailable.
    /// Single-target deployments have exactly one entry keyed by the SCSI target
    /// identifier, so we take the first stats-looking entry; multi-target
    /// matching by IQN can be added later if needed.
    static func readWriteCounts(for iqn: String) -> (readBytes: Int64, writtenBytes: Int64)? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                              IOServiceMatching("AppleSCSISubsystemGlobals"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }

        guard let raw = IORegistryEntryCreateCFProperty(svc, "Device Stats" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let stats = raw as? [String: Any] else { return nil }

        let blockSize: UInt64 = 512
        for (_, value) in stats {
            guard let d = value as? [String: Any] else { continue }
            let readBlocks  = (d["ReadBlockCount"]  as? NSNumber)?.uint64Value ?? 0
            let writeBlocks = (d["WriteBlockCount"] as? NSNumber)?.uint64Value ?? 0
            return (readBytes: Int64(readBlocks  * blockSize),
                    writtenBytes: Int64(writeBlocks * blockSize))
        }
        return nil
    }
}
