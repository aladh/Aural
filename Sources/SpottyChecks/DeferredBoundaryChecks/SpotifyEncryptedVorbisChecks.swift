import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

/// Offline decrypt-then-decode for Stage 1 (#208): wrap the synthetic `tone-44100-stereo.ogg`
/// fixture (#209) in a 0xa7-byte Spotify header, AES-128-CTR encrypt it with a test key, serve
/// the ciphertext through `RangedAudioFetcher`, and decode via `SpotifyTrackByteSource` +
/// `VorbisDecodePipeline`. Never account-derived.
@Test
@MainActor
func testSpotifyEncryptedVorbis() async {
    guard let ogg = bundledToneFixture() else { return }

    let key = testFileKey
    let plaintext = syntheticSpotifyAudioFile(ogg: ogg)
    let ciphertext: Data
    do {
        ciphertext = try AESCTRDecryptor.decrypt(key: key, offset: 0, data: plaintext)
    } catch {
        #expect((false) == true, "CTR wrapping the synthetic file did not throw: \(error)")
        return
    }

    let url = URL(string: "https://audio-ak.spotifycdn.com/audio/synthetic-tone")!
    let transport = BlobRangedTransport(blob: ciphertext)
    let fetcher = RangedAudioFetcher(url: url, transport: transport)
    let source = SpotifyTrackByteSource(fetcher: fetcher, key: key, format: .oggVorbis160)

    do {
        let total = try await source.totalLength()
        #expect((total) == (ciphertext.count), "byte source length is the encrypted file length")

        let captureStart = SpotifyTrackByteSource.oggStartOffset
        let requestedPrefix = min(64, ogg.count)
        let oggPrefix = try await source.readRange(offset: captureStart, length: requestedPrefix)
        #expect((oggPrefix.count) == (requestedPrefix), "ranged decrypt at 0xa7 returns the requested length")
        #expect((oggPrefix) == (ogg.prefix(requestedPrefix)), "ranged decrypt at 0xa7 is the Ogg fixture prefix")

        let midOffset = captureStart + 17
        let midLength = 48
        guard midOffset + midLength <= plaintext.count else {
            #expect((false) == true, "fixture is large enough for a mid-stream ranged decrypt")
            return
        }
        let mid = try await source.readRange(offset: midOffset, length: midLength)
        #expect(
            (mid) == (plaintext.subdata(in: midOffset..<(midOffset + midLength))),
            "mid-stream ranged decrypt matches the wrapped plaintext (counter carry past block 0)")
    } catch {
        #expect((false) == true, "ranged decrypt through SpotifyTrackByteSource did not throw: \(error)")
        return
    }

    await runEncryptedFixtureDecodeThroughPipeline(source: source, ogg: ogg)
}

/// Feeds the decrypting `SpotifyTrackByteSource` into `VorbisDecodePipeline` at the Ogg capture
/// offset, the same start the live path uses after skipping Spotify's header.
@MainActor
private func runEncryptedFixtureDecodeThroughPipeline(
    source: SpotifyTrackByteSource,
    ogg: Data
) async {
    let sink = FakeSink()
    let collector = EventCollector()
    let pipeline = VorbisDecodePipeline()

    pipeline.start(
        source: source,
        sink: sink,
        startOffset: SpotifyTrackByteSource.oggStartOffset,
        startPositionMs: 0
    ) { collector.record($0) }

    #expect(
        (await waitUntil(timeout: .seconds(10)) { collector.all.contains(where: isEndOfTrack) }) == true,
        "encrypted fixture decode reaches .endOfTrack")
    let events = collector.all
    let playingBeforeEnd: Bool
    if let playingIndex = events.firstIndex(where: isPlaying),
        let endOfTrackIndex = events.firstIndex(where: isEndOfTrack)
    {
        playingBeforeEnd = playingIndex < endOfTrackIndex
    } else {
        playingBeforeEnd = false
    }
    #expect((playingBeforeEnd) == true, "encrypted fixture decode emitted .playing before .endOfTrack")

    let totalFrames = sink.totalFrameCount
    #expect((totalFrames > 0) == true, "encrypted fixture decode produced frames")
    if let expectedFrames = lastGranulePosition(in: ogg) {
        #expect(
            (Int64(totalFrames)) == (expectedFrames),
            "encrypted fixture decoded frame count matches the last page's granule position")
    } else {
        #expect((false) == true, "ogg fixture has a page with a resolved granule position")
    }

    pipeline.stop()
}

/// 16-byte AES key used only by this check. Distinct from the NIST SP 800-38A vector in
/// `AESCTRDecryptorChecks` so a copy-paste mix-up would fail rather than silently reuse it.
private let testFileKey: [UInt8] = [
    0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
    0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
]

private func syntheticSpotifyAudioFile(ogg: Data) -> Data {
    var header = Data(repeating: 0, count: SpotifyAudioHeader.normalisationOffset)
    for gain: Float in [0, 1, 0, 1] {
        withUnsafeBytes(of: gain.bitPattern.littleEndian) { header.append(contentsOf: $0) }
    }
    header.append(Data(repeating: 0, count: SpotifyAudioHeader.length - header.count))
    return header + ogg
}

/// Serves slices of one in-memory CDN blob. Open/read-ahead may request any range; the live
/// fetcher learns `Content-Range` from whatever comes back.
private final class BlobRangedTransport: RangedHTTPTransport, @unchecked Sendable {
    private let blob: Data

    init(blob: Data) {
        self.blob = blob
    }

    func fetch(_ url: URL, range: ClosedRange<Int>) async throws -> RangedHTTPResponse {
        let total = blob.count
        guard total > 0 else {
            return RangedHTTPResponse(statusCode: 416, headers: [:], body: Data())
        }
        let start = min(max(range.lowerBound, 0), total)
        let endInclusive = min(range.upperBound, total - 1)
        guard start <= endInclusive else {
            return RangedHTTPResponse(
                statusCode: 416,
                headers: ["Content-Range": "bytes */\(total)"],
                body: Data()
            )
        }
        let slice = blob[start...endInclusive]
        return RangedHTTPResponse(
            statusCode: 206,
            headers: ["Content-Range": "bytes \(start)-\(endInclusive)/\(total)"],
            body: Data(slice)
        )
    }
}
