// Ported from FileTypeColors.m, Copyright (C) 2003 Tjark Derlien.

import AppKit

/// Per-map kind-name reservations, matching FileTypeColors' original palette.
@MainActor
struct FilePalette {
    private var reservations: [String: NSColor] = [:]
    private static let colors: [NSColor] = [
        (0.0, 0.0, 1.0), (1, 0, 0), (0, 1, 0),
        (0, 1, 1), (1, 0, 1), (1, 1, 0),
        (0.58, 0.58, 1), (1, 0.58, 0.58), (0.58, 1, 0.58),
        (0.58, 1, 1), (1, 0.58, 1), (1, 1, 0.58)
    ].map { OriginalCushionRenderer.normalizedColor(red: $0.0, green: $0.1, blue: $0.2) }

    mutating func reserve(statistics: [FileTypeStat], in index: DiskIndex) {
        for statistic in statistics {
            _ = color(for: index.kind(at: statistic.kindID).name)
        }
    }

    mutating func color(for kindName: String) -> NSColor {
        if let reserved = reservations[kindName] { return reserved }
        let position = reservations.count
        let color: NSColor
        if position < Self.colors.count {
            color = Self.colors[position]
        } else {
            // The original fallback is normalized gray, not a hash-derived hue.
            let gray = Double(min(Float(position) * 0.05, 0.9))
            color = OriginalCushionRenderer.normalizedColor(red: gray, green: gray, blue: gray)
        }
        reservations[kindName] = color
        return color
    }
}
