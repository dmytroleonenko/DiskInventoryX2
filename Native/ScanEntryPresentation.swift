import Foundation

/// Human-facing accounting descriptions; unavailable bytes are never presented as an empty file.
struct ScanEntryPresentation {
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func statusLabel(_ status: ScanEntryStatus) -> String? {
        switch status {
        case .complete: return nil
        case .partial: return String(localized: "entry.partial", defaultValue: "Partial scan")
        case .unreadable: return String(localized: "entry.unreadable", defaultValue: "Unreadable")
        case .cloudOnly: return String(localized: "entry.cloudOnly", defaultValue: "Cloud only")
        case .automount: return String(localized: "entry.automount", defaultValue: "Automount not opened")
        case .otherVolume: return String(localized: "entry.otherVolume", defaultValue: "Other mounted volume — scan separately")
        }
    }

    static func explanation(_ status: ScanEntryStatus) -> String? {
        switch status {
        case .complete: return nil
        case .partial:
            return String(localized: "entry.partial.help", defaultValue: "Some contents could not be measured. The displayed size is a lower bound, not the total size. Deletion is disabled until a complete scan is available.")
        case .unreadable:
            return String(localized: "entry.unreadable.help", defaultValue: "This item could not be read or measured. Its size is unknown, not zero. Check access permissions and scan again. Deletion is disabled.")
        case .cloudOnly:
            return String(localized: "entry.cloudOnly.help", defaultValue: "Cloud content was not downloaded or opened. Its local allocation is unavailable, not zero. Deletion and zoom are disabled.")
        case .automount:
            return String(localized: "entry.automount.help", defaultValue: "This automount location was not opened, to avoid mounting or contacting a remote filesystem. Its size is unknown. Deletion and zoom are disabled.")
        case .otherVolume:
            return String(localized: "entry.otherVolume.help", defaultValue: "This already-mounted filesystem was excluded from the parent scan. Its size is unknown here. Use Zoom In to scan it explicitly. Deletion is disabled.")
        }
    }

    static func isSharedAlias(_ node: DiskNode) -> Bool {
        guard let record = node.index.hardLink(at: node.id) else { return false }
        return record.ownerID != node.id
    }

    static func size(_ node: DiskNode) -> String {
        switch node.scanStatus {
        case .complete:
            return isSharedAlias(node)
                ? String(localized: "entry.countedElsewhere", defaultValue: "Already counted")
                : bytes(node.size)
        case .partial:
            return String.localizedStringWithFormat(String(localized: "entry.lowerBound", defaultValue: "At least %@"), bytes(node.size))
        case .unreadable, .cloudOnly, .automount, .otherVolume:
            return String(localized: "entry.unavailable", defaultValue: "Unavailable")
        }
    }

    static func name(_ node: DiskNode) -> String {
        if let label = statusLabel(node.scanStatus) { return "\(node.name) — \(label)" }
        if isSharedAlias(node) {
            return "\(node.name) — \(String(localized: "entry.countedElsewhere", defaultValue: "Already counted"))"
        }
        return node.name
    }

    static func details(_ node: DiskNode) -> String {
        let kind = node.isAggregate ? node.name : node.index.kind(at: node.fileKindID).name
        var result = "\(kind), \(size(node))"
        if let label = statusLabel(node.scanStatus) { result += " — \(label)" }
        if let record = node.index.hardLink(at: node.id), record.ownerID != node.id {
            result += " — " + String.localizedStringWithFormat(
                String(localized: "entry.hardlink.details", defaultValue: "Space charged to %@; original logical size %@, allocated size %@. This name does not represent an empty file or independently reclaimable space."),
                node.index.url(of: record.ownerID).path, bytes(record.logicalSize), bytes(record.allocatedSize)
            )
        }
        return result
    }

    static func tooltip(_ node: DiskNode) -> String {
        var text = "\(node.url.path)\n\(details(node))"
        if let explanation = explanation(node.scanStatus) { text += "\n\(explanation)" }
        return text
    }

    static func canZoom(_ node: DiskNode) -> Bool {
        guard node.isDirectory else { return false }
        switch node.scanStatus {
        case .complete, .partial, .otherVolume: return true
        case .unreadable, .cloudOnly, .automount: return false
        }
    }

    static var volumeExplanation: String {
        String(localized: "space.explanation", defaultValue: "The scan allocation covers the full scan root, including when zoomed or displaying logical sizes. Not accounted space can include snapshots, filesystem metadata, unreadable or excluded data, and other volumes in a shared APFS container. Excess allocation can reflect shared APFS blocks or different accounting scopes. These are filesystem snapshots, not exact reclaimable space; no snapshot size is inferred.")
    }

    static func volumeSummary(_ index: DiskIndex) -> String {
        guard let snapshot = index.volumeSpace else {
            return String(localized: "space.unavailable", defaultValue: "Volume space snapshot unavailable; unaccounted space cannot be determined.")
        }
        let allocated = index.entry(at: 0).allocatedSize
        let used = snapshot.usedBytes
        let totals = String.localizedStringWithFormat(
            String(localized: "space.totals", defaultValue: "Volume %@ — Capacity %@ • Used %@ • Free %@"),
            snapshot.volumeURL.path, bytes(snapshot.capacityBytes), bytes(used), bytes(snapshot.freeBytes)
        )
        let accounting: String
        if allocated > used {
            accounting = String.localizedStringWithFormat(
                String(localized: "space.excess", defaultValue: "Full scan allocated %@ • Allocation exceeds volume used by %@ (shared blocks / accounting scope)"),
                bytes(allocated), bytes(allocated - used)
            )
        } else {
            accounting = String.localizedStringWithFormat(
                String(localized: "space.unaccounted", defaultValue: "Full scan allocated %@ • Not accounted by scan %@"),
                bytes(allocated), bytes(used - allocated)
            )
        }
        return totals + "\n" + accounting + "\n" + String(localized: "space.disclaimer", defaultValue: "Snapshot, not reclaimable space. Unaccounted bytes may include snapshots, metadata, excluded data and shared-container volumes.")
    }
}
