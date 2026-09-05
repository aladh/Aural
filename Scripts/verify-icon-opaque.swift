import AppKit

// Border-opacity gate for the macOS app icon source artwork. macOS Tahoe
// places icons with transparent edges inside a gray squircle in the Dock,
// so the source must be opaque edge-to-edge. Reads raw 8-bit samples with
// the same packed-sample contract as assemble-icns.swift. Opaque RGB (and
// RGBX pad-byte) input carries no alpha plane and passes trivially.
//
// Exit 0: every border pixel is fully opaque.
// Exit 1: at least one border pixel is transparent.
// Exit 2: usage error or unreadable/unsupported artwork.

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: verify-icon-opaque.swift <source.png>\n".utf8))
    exit(2)
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let data = try Data(contentsOf: url)
    guard let bitmap = NSBitmapImageRep(data: data),
        bitmap.pixelsWide > 0,
        bitmap.pixelsHigh > 0,
        !bitmap.isPlanar,
        bitmap.bitsPerSample == 8,
        (bitmap.samplesPerPixel == 3 || bitmap.samplesPerPixel == 4),
        bitmap.bytesPerRow >= bitmap.pixelsWide * bitmap.samplesPerPixel,
        let samples = bitmap.bitmapData
    else {
        throw CocoaError(.fileReadCorruptFile)
    }

    let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
    let samplesPerPixel = bitmap.samplesPerPixel
    let hasAlphaPlane = bitmap.hasAlpha && samplesPerPixel == 4
    let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : samplesPerPixel - 1
    var transparent = 0
    if hasAlphaPlane {
        // Each scan covers distinct coordinates: the bottom row only when it
        // differs from the top, the side columns only when they differ from
        // each other, and the side scan skips the corner rows, so every
        // border pixel counts exactly once.
        for x in 0..<width {
            if samples[x * samplesPerPixel + alphaOffset] != 255 {
                transparent += 1
            }
            if height > 1,
                samples[(height - 1) * bitmap.bytesPerRow + x * samplesPerPixel + alphaOffset] != 255
            {
                transparent += 1
            }
        }
        if width > 1, height > 2 {
            for y in 1..<(height - 1) {
                if samples[y * bitmap.bytesPerRow + alphaOffset] != 255 {
                    transparent += 1
                }
                if samples[y * bitmap.bytesPerRow + (width - 1) * samplesPerPixel + alphaOffset] != 255 {
                    transparent += 1
                }
            }
        }
    }
    if transparent > 0 {
        FileHandle.standardError.write(Data("\(transparent) border pixels are not fully opaque\n".utf8))
        exit(1)
    }
} catch {
    FileHandle.standardError.write(Data("Unable to read \(url.path): \(error)\n".utf8))
    exit(2)
}
