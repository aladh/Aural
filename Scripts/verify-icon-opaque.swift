import AppKit

// Border-opacity gate for the macOS app icon source artwork. macOS Tahoe
// places icons with transparent edges inside a gray squircle in the Dock,
// so the source must be opaque edge-to-edge. Reads raw 8-bit samples with
// the same packed-sample contract as assemble-icns.swift.
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
        bitmap.samplesPerPixel == 4,
        bitmap.bitsPerSample == 8,
        bitmap.bytesPerRow == bitmap.pixelsWide * 4,
        let samples = bitmap.bitmapData
    else {
        throw CocoaError(.fileReadCorruptFile)
    }

    let width = bitmap.pixelsWide, height = bitmap.pixelsHigh
    let alphaOffset = bitmap.bitmapFormat.contains(.alphaFirst) ? 0 : 3
    var transparent = 0
    // The side scan skips the corner rows so each border pixel counts once.
    for x in 0..<width {
        for y in [0, height - 1] {
            if samples[y * bitmap.bytesPerRow + x * 4 + alphaOffset] != 255 {
                transparent += 1
            }
        }
    }
    if height > 2 {
        for y in 1..<(height - 1) {
            for x in [0, width - 1] {
                if samples[y * bitmap.bytesPerRow + x * 4 + alphaOffset] != 255 {
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
