// Ported from TreeMapView/TMVCushionRenderer.m, Copyright (c) 2003 Tjark Derlien.

import Foundation

/// The original renderer's quadratic surface coefficients, inherited by descendants.
struct OriginalCushionSurface {
    var x2 = 0.0
    var y2 = 0.0
    var x = 0.0
    var y = 0.0

    func addingRidge(in rect: NSRect, heightFactor: Float) -> Self {
        var surface = self
        let h4 = Double(4 * heightFactor)
        let wf = h4 / Double(rect.width)
        surface.x += wf * Double(rect.maxX + rect.minX)
        surface.x2 -= wf
        let hf = h4 / Double(rect.height)
        surface.y += hf * Double(rect.maxY + rect.minY)
        surface.y2 -= hf
        return surface
    }
}
