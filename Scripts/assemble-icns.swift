import AppKit

private enum Encoding {
    case argb
    case png
}

private struct Representation {
    let type: String
    let filename: String
    let pixels: UInt32
    let encoding: Encoding
}

private let representations = [
    // Finder still expects legacy ARGB payloads for the non-Retina 16- and 32-pixel slots.
    // Treating ic04/ic05 (or icp4/icp5) as ordinary PNG containers produces striped icons.
    Representation(type: "ic04", filename: "icon_16x16.png", pixels: 16, encoding: .argb),
    Representation(type: "ic11", filename: "icon_16x16@2x.png", pixels: 32, encoding: .png),
    Representation(type: "ic05", filename: "icon_32x32.png", pixels: 32, encoding: .argb),
    Representation(type: "ic12", filename: "icon_32x32@2x.png", pixels: 64, encoding: .png),
    Representation(type: "ic07", filename: "icon_128x128.png", pixels: 128, encoding: .png),
    Representation(type: "ic13", filename: "icon_128x128@2x.png", pixels: 256, encoding: .png),
    Representation(type: "ic08", filename: "icon_256x256.png", pixels: 256, encoding: .png),
    Representation(type: "ic14", filename: "icon_256x256@2x.png", pixels: 512, encoding: .png),
    Representation(type: "ic09", filename: "icon_512x512.png", pixels: 512, encoding: .png),
    Representation(type: "ic10", filename: "icon_512x512@2x.png", pixels: 1024, encoding: .png),
]

private func bigEndianUInt32(in data: Data, at offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
}

private func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
}

private func runLengthEncode(_ channel: [UInt8]) -> Data {
    var encoded = Data()
    var index = 0

    while index < channel.count {
        var runLength = 1
        while index + runLength < channel.count,
            runLength < 130,
            channel[index + runLength] == channel[index]
        {
            runLength += 1
        }

        if runLength >= 3 {
            encoded.append(UInt8(runLength + 125))
            encoded.append(channel[index])
            index += runLength
            continue
        }

        let literalStart = index
        index += 1
        while index < channel.count, index - literalStart < 128 {
            var nextRunLength = 1
            while index + nextRunLength < channel.count,
                nextRunLength < 3,
                channel[index + nextRunLength] == channel[index]
            {
                nextRunLength += 1
            }
            if nextRunLength >= 3 { break }
            index += 1
        }

        let literalLength = index - literalStart
        encoded.append(UInt8(literalLength - 1))
        encoded.append(contentsOf: channel[literalStart..<index])
    }

    return encoded
}

private func argbPayload(from png: Data, pixels: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(data: png),
        bitmap.pixelsWide == pixels,
        bitmap.pixelsHigh == pixels,
        !bitmap.isPlanar,
        bitmap.bitsPerSample == 8,
        (bitmap.samplesPerPixel == 3 || bitmap.samplesPerPixel == 4),
        bitmap.bytesPerRow >= pixels * bitmap.samplesPerPixel,
        let samples = bitmap.bitmapData
    else {
        throw CocoaError(.fileReadCorruptFile)
    }

    // Store the raw 8-bit samples exactly as iconutil does. Converting the
    // pixels through a color space first brightens translucent RGB past its
    // alpha, and Icon Services clamps those channels back to white on decode
    // (a 16 px icon full of white-fringed edges fails the round-trip check).
    // Opaque RGB (and RGBX pad-byte) input carries no alpha plane, so those
    // pixels assemble with a fully opaque alpha channel. AppKit expands RGB
    // samples to RGBX in memory: samplesPerPixel still reports 3 while each
    // row holds 4 bytes per pixel with an opaque pad byte, so the in-memory
    // stride is detected instead of assumed.
    let samplesPerPixel = bitmap.samplesPerPixel
    let pixelStride: Int
    if samplesPerPixel == 4 {
        pixelStride = 4
    } else if bitmap.bytesPerRow == pixels * 3 {
        pixelStride = 3
    } else if bitmap.bytesPerRow == pixels * 4 {
        pixelStride = 4
    } else {
        throw CocoaError(.fileReadCorruptFile)
    }
    guard bitmap.bytesPerRow >= pixels * pixelStride else {
        throw CocoaError(.fileReadCorruptFile)
    }
    let hasAlphaPlane = bitmap.hasAlpha && samplesPerPixel == 4
    let alphaFirst = bitmap.bitmapFormat.contains(.alphaFirst)
    let alphaOffset = alphaFirst ? 0 : pixelStride - 1
    let redOffset = alphaFirst && pixelStride == 4 ? 1 : 0
    let greenOffset = alphaFirst && pixelStride == 4 ? 2 : 1
    let blueOffset = alphaFirst && pixelStride == 4 ? 3 : 2

    var alpha = [UInt8]()
    var red = [UInt8]()
    var green = [UInt8]()
    var blue = [UInt8]()
    alpha.reserveCapacity(pixels * pixels)
    red.reserveCapacity(pixels * pixels)
    green.reserveCapacity(pixels * pixels)
    blue.reserveCapacity(pixels * pixels)

    for y in 0..<pixels {
        let row = y * bitmap.bytesPerRow
        for x in 0..<pixels {
            let base = row + x * pixelStride
            alpha.append(hasAlphaPlane ? samples[base + alphaOffset] : 255)
            red.append(samples[base + redOffset])
            green.append(samples[base + greenOffset])
            blue.append(samples[base + blueOffset])
        }
    }

    var payload = Data("ARGB".utf8)
    for channel in [alpha, red, green, blue] {
        payload.append(runLengthEncode(channel))
    }
    return payload
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: assemble-icns.swift <iconset> <output.icns>\n".utf8))
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let pngSignature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
var chunks = Data()

do {
    for representation in representations {
        let pngURL = iconsetURL.appendingPathComponent(representation.filename)
        let png = try Data(contentsOf: pngURL)
        guard png.count >= 24, png.prefix(pngSignature.count) == pngSignature else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: pngURL.path])
        }

        let width = bigEndianUInt32(in: png, at: 16)
        let height = bigEndianUInt32(in: png, at: 20)
        guard width == representation.pixels, height == representation.pixels else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSFilePathErrorKey: pngURL.path,
                    NSLocalizedDescriptionKey:
                        "Expected \(representation.pixels)×\(representation.pixels), found \(width)×\(height)",
                ])
        }

        let payload: Data
        switch representation.encoding {
        case .argb:
            payload = try argbPayload(from: png, pixels: Int(representation.pixels))
        case .png:
            payload = png
        }

        chunks.append(Data(representation.type.utf8))
        appendBigEndian(UInt32(payload.count + 8), to: &chunks)
        chunks.append(payload)
    }

    var icns = Data("icns".utf8)
    appendBigEndian(UInt32(chunks.count + 8), to: &icns)
    icns.append(chunks)
    try icns.write(to: outputURL, options: .atomic)
} catch {
    FileHandle.standardError.write(Data("Unable to assemble \(outputURL.path): \(error)\n".utf8))
    exit(1)
}
