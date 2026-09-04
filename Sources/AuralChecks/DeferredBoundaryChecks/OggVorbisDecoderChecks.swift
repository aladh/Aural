import AuralCore
import AuralDomain
import Foundation

@MainActor
func runOggVorbisDecoderChecks(_ check: CheckRunner) {
    check.suite("Ogg Vorbis pushdata decoder") {
        check.check("empty buffer throws needMoreData, not success or another error", emptyBufferThrowsNeedMoreData())

        check.throwsError("garbage bytes never open successfully (4 KiB deterministic LCG stream)") {
            let garbage = lcgBytes(count: 4_096, seed: 0x1234_5678_9abc_def0)
            let decoder = OggVorbisDecoder()
            _ = try garbage.withUnsafeBytes { try decoder.openHeaders($0) }
        }

        runFixtureDecodeCheck(check)
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
/// against the file's own Ogg page framing. The fixture must be a synthetic generated tone (see
/// the PR description for the exact ffmpeg invocation), never an account-derived file, so it is
/// deliberately not committed by this change; until someone adds it on a machine with an encoder,
/// this records one passing "skipped" check instead of failing the gate.
@MainActor
private func runFixtureDecodeCheck(_ check: CheckRunner) {
    let data: Data
    do {
        data = try boundaryFixture(named: "tone-44100-stereo", extension: "ogg")
    } catch {
        check.check("tone-44100-stereo.ogg fixture absent; decode check skipped", true)
        return
    }

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
            check.check("fixture headers open: unexpected error \(error)", false)
            return
        }
    }
    guard let consumed = headerBytesConsumed else {
        check.check("fixture headers open before the file is exhausted", false)
        return
    }

    check.equal("fixture sample rate", decoder.sampleRate, 44_100)
    check.equal("fixture channel count", decoder.channels, 2)

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
            check.check("fixture frame decode: unexpected error \(error)", false)
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

    check.check("fixture decode produced frames", totalFrames > 0)
    if let expectedFrames = lastGranulePosition(in: data) {
        check.equal(
            "fixture decoded frame count matches the last page's granule position",
            Int64(totalFrames),
            expectedFrames
        )
    } else {
        check.check("fixture has a page with a resolved granule position", false)
    }

    guard !pcm.isEmpty else {
        check.check("fixture decoded samples are non-silent", false)
        return
    }
    let meanAbsoluteSample = pcm.reduce(Float(0)) { $0 + abs($1) } / Float(pcm.count)
    check.check("fixture decoded samples are non-silent (mean |sample| > 0.01)", meanAbsoluteSample > 0.01)
}
