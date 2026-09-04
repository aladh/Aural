import Testing
import SpottyCore
import SpottyDomain
import Foundation

@Test
@MainActor
func testOggVorbisDecoder() {
    do {
        #expect(
            (emptyBufferThrowsNeedMoreData()) == true, "empty buffer throws needMoreData, not success or another error")

        do {
            var didThrow = false
            do {
                let garbage = lcgBytes(count: 4_096, seed: 0x1234_5678_9abc_def0)
                let decoder = OggVorbisDecoder()
                _ = try garbage.withUnsafeBytes { try decoder.openHeaders($0) }

            } catch {
                didThrow = true
            }
            #expect(didThrow, "garbage bytes never open successfully (4 KiB deterministic LCG stream)")
        }

        runFixtureDecodeCheck()
    }
}

private func emptyBufferThrowsNeedMoreData() -> Bool {
    let decoder = OggVorbisDecoder()
    do {
        _ = try [UInt8]().withUnsafeBytes { try decoder.openHeaders($0) }
        return false
    } catch OggVorbisDecoderError.needMoreData {
        return true
    } catch {
        return false
    }
}

/// Feeds `Fixtures/tone-44100-stereo.ogg` through the decoder in 4 KiB slices and checks it
/// against the file's own Ogg page framing. The fixture is a one-second synthetic 440 Hz tone
/// (44.1 kHz stereo, libvorbis), never account-derived.
@MainActor
private func runFixtureDecodeCheck() {
    guard let data = bundledToneFixture() else { return }

    let decoder = OggVorbisDecoder()

    // Open headers, growing the fed prefix by 4 KiB each time stb_vorbis asks for more --
    // pushdata semantics require re-feeding from the start of the file, not just the new bytes.
    var headerWindowEnd = min(4_096, data.count)
    var headerBytesConsumed: Int?
    while headerBytesConsumed == nil {
        let prefix = Array(data.prefix(headerWindowEnd))
        do {
            headerBytesConsumed = try prefix.withUnsafeBytes { try decoder.openHeaders($0) }
        } catch OggVorbisDecoderError.needMoreData {
            guard headerWindowEnd < data.count else { break }
            headerWindowEnd = min(headerWindowEnd + 4_096, data.count)
        } catch {
            #expect((false) == true, "fixture headers open: unexpected error \(error)")
            return
        }
    }
    guard let consumed = headerBytesConsumed else {
        #expect((false) == true, "fixture headers open before the file is exhausted")
        return
    }

    #expect((decoder.sampleRate) == (44_100), "fixture sample rate")
    #expect((decoder.channels) == (2), "fixture channel count")

    var pcm: [Float] = []
    var frameBuffer: [Float] = []
    var totalFrames = 0
    var cursor = consumed
    var windowEnd = min(cursor + 4_096, data.count)
    var iterationsRemaining = data.count + 10_000  // guards this check against an infinite loop, not the decoder

    while iterationsRemaining > 0 {
        iterationsRemaining -= 1
        let slice = Array(data[(data.startIndex + cursor)..<(data.startIndex + windowEnd)])
        let result: (consumed: Int, frames: Int)
        do {
            result = try slice.withUnsafeBytes { try decoder.decodeFrame($0, into: &frameBuffer) }
        } catch {
            #expect((false) == true, "fixture frame decode: unexpected error \(error)")
            return
        }

        if result.consumed == 0, result.frames == 0 {
            guard windowEnd < data.count else { break }  // no more bytes to offer; done
            windowEnd = min(windowEnd + 4_096, data.count)
            continue
        }

        cursor += result.consumed
        if result.frames > 0 {
            totalFrames += result.frames
            pcm.append(contentsOf: frameBuffer)
        }
        windowEnd = min(cursor + 4_096, data.count)
    }

    #expect((totalFrames > 0) == true, "fixture decode produced frames")
    if let expectedFrames = lastGranulePosition(in: data) {
        #expect(
            (Int64(totalFrames)) == (expectedFrames),
            "fixture decoded frame count matches the last page's granule position")
    } else {
        #expect((false) == true, "fixture has a page with a resolved granule position")
    }

    guard !pcm.isEmpty else {
        #expect((false) == true, "fixture decoded samples are non-silent")
        return
    }
    let meanAbsoluteSample = pcm.reduce(Float(0)) { $0 + abs($1) } / Float(pcm.count)
    #expect((meanAbsoluteSample > 0.01) == true, "fixture decoded samples are non-silent (mean |sample| > 0.01)")
}
