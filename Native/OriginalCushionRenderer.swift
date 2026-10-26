// Ported from TreeMapView/TMVCushionRenderer.m, Copyright (c) 2003 Tjark Derlien.

import AppKit

/// Literal generic TMVCushionRenderer equations and RGB saturation redistribution.
@MainActor
struct OriginalCushionRenderer {
    static let baseBrightness = Double(Float(1.8))

    static func normalize(red: inout Double, green: inout Double, blue: inout Double) {
        if red > 1 {
            distribute(first: &red, second: &green, third: &blue)
        } else if green > 1 {
            distribute(first: &green, second: &red, third: &blue)
        } else if blue > 1 {
            distribute(first: &blue, second: &red, third: &green)
        }
    }

    private static func distribute(first: inout Double, second: inout Double, third: inout Double) {
        var excess = (first - 1) / 2
        first = 1
        second += excess
        third += excess
        if second > 1 {
            excess = second - 1
            second = 1
            third += excess
        } else if third > 1 {
            excess = third - 1
            third = 1
            second += excess
        }
    }

    static func normalizedColor(red: Double, green: Double, blue: Double) -> NSColor {
        let sum = red + green + blue
        let factor = sum != 0 ? baseBrightness / sum : 1
        var r = red * factor
        var g = green * factor
        var b = blue * factor
        normalize(red: &r, green: &g, blue: &b)
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1)
    }

    static func render(
        rect: NSRect, surface: OriginalCushionSurface, color: NSColor,
        into bitmap: NSBitmapImageRep
    ) {
        guard rect.width > 0, rect.height > 0, let pixels = bitmap.bitmapData,
              let rgb = color.usingColorSpace(.genericRGB) else { return }
        let r = Double(rgb.redComponent)
        let g = Double(rgb.greenComponent)
        let b = Double(rgb.blueComponent)
        let length = sqrt(102.0)
        let lx = -1 / length
        let ly = -1 / length
        let lz = 10 / length
        let bytesPerPixel = bitmap.bitsPerPixel / 8
        for iy in Int(rect.minY)..<Int(rect.maxY) {
            let row = pixels + iy * bitmap.bytesPerRow
            let ny = -(2 * surface.y2 * (Double(iy) + 0.5) + surface.y)
            for ix in Int(rect.minX)..<Int(rect.maxX) {
                let nx = -(2 * surface.x2 * (Double(ix) + 0.5) + surface.x)
                let cosine = (nx * lx + ny * ly + lz) / sqrt(nx * nx + ny * ny + 1)
                var brightness = 0.85 * cosine
                brightness = brightness < 0 ? 0.15 : brightness + 0.15
                brightness *= 2.5 / baseBrightness
                var red = r * brightness
                var green = g * brightness
                var blue = b * brightness
                normalize(red: &red, green: &green, blue: &blue)
                let pixel = row + ix * bytesPerPixel
                pixel[0] = UInt8(red * 255)
                pixel[1] = UInt8(green * 255)
                pixel[2] = UInt8(blue * 255)
                if bytesPerPixel == 4 { pixel[3] = 255 }
            }
        }
    }
}
