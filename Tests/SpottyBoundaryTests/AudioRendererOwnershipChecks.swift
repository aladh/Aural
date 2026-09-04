import Testing
import Foundation

@Suite("Audio Renderer Ownership")
struct AudioRendererOwnershipTests {
    @Test
    @MainActor
    func testAudioRendererOwnership() {
        do {
            do {
                do {
                    let source = try audioRendererSource()

                    #expect(
                        (source.contains("CFAllocatorAllocate(kCFAllocatorDefault, chunkSize, 0)")
                            && !source.contains(
                                "UnsafeMutableRawPointer.allocate(byteCount: chunkSize"
                            )) == true, "temporary PCM chunks use Core Foundation allocation")
                    #expect(
                        (source.contains("blockAllocator: kCFAllocatorDefault")) == true,
                        "Core Media releases successful chunks through the matching allocator")
                    #expect(
                        (source.contains("CFAllocatorDeallocate(kCFAllocatorDefault, chunk)")
                            && !source.contains("chunk.deallocate()")) == true,
                        "failed block creation releases chunks through the matching allocator")

                } catch {
                    Issue.record("\("renderer source is readable"): unexpected error \(error)")
                }
            }
        }
    }
}

private func audioRendererSource() throws -> String {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Sources")
        .appending(path: "Spotty/Spotify/AudioRenderer.swift")
    return try String(contentsOf: url, encoding: .utf8)
}
