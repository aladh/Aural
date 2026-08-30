import AppKit

private let filenames = [
    "icon_16x16.png",
    "icon_16x16@2x.png",
    "icon_32x32.png",
    "icon_32x32@2x.png",
    "icon_128x128.png",
    "icon_128x128@2x.png",
    "icon_256x256.png",
    "icon_256x256@2x.png",
    "icon_512x512.png",
    "icon_512x512@2x.png",
]

private func bitmap(at url: URL) throws -> NSBitmapImageRep {
    let data = try Data(contentsOf: url)
    guard let bitmap = NSBitmapImageRep(data: data) else {
        throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
    }
    return bitmap
}

private func components(of color: NSColor) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    guard let rgb = color.usingColorSpace(.deviceRGB) else {
        throw CocoaError(.fileReadCorruptFile)
    }
    return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
}

private func imagesMatch(_ expected: NSBitmapImageRep, _ actual: NSBitmapImageRep) throws -> Bool {
    guard expected.pixelsWide == actual.pixelsWide,
        expected.pixelsHigh == actual.pixelsHigh
    else {
        return false
    }

    // Icon Services may re-encode pixels and normalize antialiased edge colors. Compare average
    // alpha and premultiplied-color error so those edge differences pass while visual corruption
    // across a representation still fails loudly.
    var totalDifference = CGFloat.zero
    var componentCount = 0
    for y in 0..<expected.pixelsHigh {
        for x in 0..<expected.pixelsWide {
            guard let expectedColor = expected.colorAt(x: x, y: y),
                let actualColor = actual.colorAt(x: x, y: y)
            else {
                return false
            }
            let lhs = try components(of: expectedColor)
            let rhs = try components(of: actualColor)
            totalDifference += abs(lhs.alpha - rhs.alpha)
            totalDifference += abs((lhs.red * lhs.alpha) - (rhs.red * rhs.alpha))
            totalDifference += abs((lhs.green * lhs.alpha) - (rhs.green * rhs.alpha))
            totalDifference += abs((lhs.blue * lhs.alpha) - (rhs.blue * rhs.alpha))
            componentCount += 4
        }
    }
    return totalDifference / CGFloat(componentCount) <= 0.025
}

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: verify-icon.swift <expected.iconset> <actual.iconset>\n".utf8))
    exit(2)
}

let expectedURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let actualURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
do {
    for filename in filenames {
        let expected = try bitmap(at: expectedURL.appendingPathComponent(filename))
        let actual = try bitmap(at: actualURL.appendingPathComponent(filename))
        guard try imagesMatch(expected, actual) else {
            throw CocoaError(
                .fileReadCorruptFile,
                userInfo: [
                    NSFilePathErrorKey: actualURL.appendingPathComponent(filename).path,
                    NSLocalizedDescriptionKey: "Icon representation does not survive its ICNS round trip",
                ])
        }
    }
} catch {
    FileHandle.standardError.write(Data("Generated icon verification failed: \(error)\n".utf8))
    exit(1)
}
