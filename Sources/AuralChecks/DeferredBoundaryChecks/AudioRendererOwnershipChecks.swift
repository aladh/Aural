import Foundation

@MainActor
func runAudioRendererOwnershipChecks(_ check: CheckRunner) {
    check.suite("Audio renderer chunk ownership") {
        check.noThrow("renderer source is readable") {
            let source = try audioRendererSource()

            check.check(
                "temporary PCM chunks use Core Foundation allocation",
                source.contains("CFAllocatorAllocate(kCFAllocatorDefault, chunkSize, 0)")
                    && !source.contains(
                        "UnsafeMutableRawPointer.allocate(byteCount: chunkSize"
                    )
            )
            check.check(
                "Core Media releases successful chunks through the matching allocator",
                source.contains("blockAllocator: kCFAllocatorDefault")
            )
            check.check(
                "failed block creation releases chunks through the matching allocator",
                source.contains("CFAllocatorDeallocate(kCFAllocatorDefault, chunk)")
                    && !source.contains("chunk.deallocate()")
            )
        }
    }
}

private func audioRendererSource() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Aural/Spotify/AudioRenderer.swift")
    return try String(contentsOf: url, encoding: .utf8)
}
