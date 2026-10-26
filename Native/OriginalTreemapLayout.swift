// Ported from TreeMapView/TMVItem.m, Copyright (c) 2003 Tjark Derlien.

import Foundation

/// TMVItem's fixed-orientation strip rows, in integer backing pixels.
struct OriginalTreemapLayout {
    static func layout(
        weights: [Int64], totalWeight: Int64, in rect: NSRect,
        place: (Int, NSRect) -> Void
    ) {
        layout(count: weights.count, totalWeight: totalWeight, in: rect, weight: { weights[$0] }, place: place)
    }

    static func layout(
        count: Int, totalWeight: Int64, in rect: NSRect,
        weight: (Int) -> Int64, place: (Int, NSRect) -> Void
    ) {
        guard count > 0 else { return }
        let horizontal = totalWeight == 0 || rect.width >= rect.height
        let parentWidth = Int(horizontal ? rect.width : rect.height)
        let parentHeight = Int(horizontal ? rect.height : rect.width)
        let parentBottom = Int(horizontal ? rect.maxY : rect.maxX)
        let parentRight = Int(horizontal ? rect.maxX : rect.maxY)
        let parentLeft = Int(horizontal ? rect.minX : rect.minY)
        let shortSide = horizontal ? rect.height : rect.width
        let aspect = shortSide > 0 ? Double(horizontal ? rect.width : rect.height) / Double(shortSide) : 1
        var top = Int(horizontal ? rect.minY : rect.minX)
        var start = 0
        while start < count {
            var end = start
            var rowHeight = 0.0
            if totalWeight == 0 {
                end = count
                rowHeight = 1
            } else {
                var sizeUsed = 0.0
                while end < count {
                    let childSize = Double(weight(end))
                    if childSize == 0 { break }
                    sizeUsed += childSize
                    let virtualHeight = sizeUsed / Double(totalWeight)
                    let childWidth = childSize / Double(totalWeight) * aspect / virtualHeight
                    if childWidth / virtualHeight < 0.4 { break }
                    rowHeight = virtualHeight
                    end += 1
                }
                while end < count, weight(end) == 0 { end += 1 }
            }
            guard end > start else { return }
            // Objective-C calls roundf, not round: the conversion to Float matters.
            var bottom = top + Int(Float(rowHeight * Double(parentHeight)).rounded(.toNearestOrAwayFromZero))
            if bottom > parentBottom || end == count { bottom = parentBottom }
            var left = parentLeft
            let rowSize = Double(totalWeight) * rowHeight
            for child in start..<end {
                let fraction = totalWeight == 0 ? 1 / Double(count) : Double(weight(child)) / rowSize
                var right = left + Int(Float(fraction * Double(parentWidth)).rounded(.toNearestOrAwayFromZero))
                if right > parentRight || child == end - 1 { right = parentRight }
                let childRect = horizontal
                    ? NSRect(x: CGFloat(left), y: CGFloat(top), width: CGFloat(right - left), height: CGFloat(bottom - top))
                    : NSRect(x: CGFloat(top), y: CGFloat(left), width: CGFloat(bottom - top), height: CGFloat(right - left))
                place(child, childRect)
                left = right
            }
            top = bottom
            start = end
        }
    }
}
