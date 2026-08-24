import AppKit

private struct Output {
    let pixels: Int
    let filenames: [String]
}

private let outputs = [
    Output(pixels: 16, filenames: ["icon_16x16.png"]),
    Output(pixels: 32, filenames: ["icon_16x16@2x.png", "icon_32x32.png"]),
    Output(pixels: 64, filenames: ["icon_32x32@2x.png"]),
]

private func point(_ x: CGFloat, _ y: CGFloat, size: CGFloat) -> CGPoint {
    CGPoint(x: x * size, y: y * size)
}

private func renderIcon(pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    let size = CGFloat(pixels)
    let context = graphicsContext.cgContext
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }

    context.clear(CGRect(x: 0, y: 0, width: size, height: size))
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)

    let inset = max(0.75, size * 0.055)
    let tile = CGRect(x: inset, y: inset, width: size - (inset * 2), height: size - (inset * 2))
    let tilePath = CGPath(
        roundedRect: tile,
        cornerWidth: size * 0.23,
        cornerHeight: size * 0.23,
        transform: nil
    )
    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let background = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.04, green: 0.15, blue: 0.58, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.00, green: 0.47, blue: 0.93, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.00, green: 0.78, blue: 0.72, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 0.58, 1]
    )!
    context.drawLinearGradient(
        background,
        start: point(0.12, 0.90, size: size),
        end: point(0.90, 0.08, size: size),
        options: []
    )

    let highlight = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.24).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        highlight,
        startCenter: point(0.70, 0.82, size: size),
        startRadius: 0,
        endCenter: point(0.70, 0.82, size: size),
        endRadius: size * 0.68,
        options: []
    )
    context.restoreGState()

    context.addPath(tilePath)
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.28).cgColor)
    context.setLineWidth(max(0.5, size * 0.025))
    context.strokePath()

    let waveform = CGMutablePath()
    waveform.move(to: point(0.15, 0.44, size: size))
    waveform.addCurve(
        to: point(0.31, 0.49, size: size),
        control1: point(0.22, 0.44, size: size),
        control2: point(0.24, 0.49, size: size)
    )
    waveform.addCurve(
        to: point(0.45, 0.31, size: size),
        control1: point(0.39, 0.49, size: size),
        control2: point(0.38, 0.31, size: size)
    )
    waveform.addCurve(
        to: point(0.58, 0.72, size: size),
        control1: point(0.52, 0.31, size: size),
        control2: point(0.51, 0.72, size: size)
    )
    waveform.addCurve(
        to: point(0.72, 0.40, size: size),
        control1: point(0.65, 0.72, size: size),
        control2: point(0.65, 0.40, size: size)
    )
    waveform.addCurve(
        to: point(0.85, 0.50, size: size),
        control1: point(0.79, 0.40, size: size),
        control2: point(0.79, 0.50, size: size)
    )

    context.addPath(waveform)
    context.setStrokeColor(NSColor(calibratedRed: 0.25, green: 0.95, blue: 1, alpha: 0.48).cgColor)
    context.setLineWidth(max(2.5, size * 0.19))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()

    context.addPath(waveform)
    context.setStrokeColor(NSColor.white.cgColor)
    context.setLineWidth(max(1.35, size * 0.085))
    context.strokePath()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: render-small-icons.swift <iconset>\n".utf8))
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    for output in outputs {
        let png = try renderIcon(pixels: output.pixels)
        for filename in output.filenames {
            try png.write(to: iconsetURL.appendingPathComponent(filename), options: .atomic)
        }
    }
} catch {
    FileHandle.standardError.write(Data("Unable to render small icons: \(error)\n".utf8))
    exit(1)
}
