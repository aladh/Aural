//
//  SpotifyAudioFileChecks.swift
//  Spotty
//

import SpottyDomain
import Foundation

func runSpotifyAudioFileChecks(_ check: CheckRunner) {
    check.suite("Spotify audio format bitrates") {
        let expected: [SpotifyAudioFormat: Int?] = [
            .oggVorbis96: 96,
            .oggVorbis160: 160,
            .oggVorbis320: 320,
            .mp3_256: 256,
            .mp3_320: 320,
            .mp3_160: 160,
            .mp3_96: 96,
            .mp3_160Enc: 160,
            .aac24: 24,
            .aac48: 48,
            .flac: nil,
        ]
        for (format, kbps) in expected {
            check.equal("\(format) kilobitsPerSecond", format.kilobitsPerSecond, kbps)
            check.equal("\(format) bytesPerSecond", format.bytesPerSecond, kbps.map { $0 / 8 * 1024 })
        }

        for format: SpotifyAudioFormat in [.oggVorbis96, .oggVorbis160, .oggVorbis320] {
            check.check("\(format) isOggVorbis", format.isOggVorbis)
        }
        for format: SpotifyAudioFormat in [.mp3_256, .mp3_320, .mp3_160, .mp3_96, .mp3_160Enc, .aac24, .aac48, .flac] {
            check.check("\(format) is not Ogg Vorbis", !format.isOggVorbis)
        }

        check.equal("librespot raw value: oggVorbis96", SpotifyAudioFormat.oggVorbis96.rawValue, 0)
        check.equal("librespot raw value: mp3_256", SpotifyAudioFormat.mp3_256.rawValue, 3)
        check.equal("librespot raw value: aac48", SpotifyAudioFormat.aac48.rawValue, 9)
        check.equal("librespot raw value: flac", SpotifyAudioFormat.flac.rawValue, 16)
    }

    check.suite("Spotify audio header parsing") {
        let gains: [Float] = [-3.5, 0.891, -2.0, 0.75]

        func header(gains: [Float], withOggMagic: Bool, trailingPadding: Int = 0) -> Data {
            var data = Data(repeating: 0, count: SpotifyAudioHeader.normalisationOffset)
            for gain in gains {
                withUnsafeBytes(of: gain.bitPattern.littleEndian) { data.append(contentsOf: $0) }
            }
            data.append(Data(repeating: 0, count: SpotifyAudioHeader.length - data.count))
            if withOggMagic {
                data.append(Data("OggS".utf8))
            }
            data.append(Data(repeating: 0, count: trailingPadding))
            return data
        }

        check.equal("header length constant", SpotifyAudioHeader.length, 0xa7)
        check.equal("normalisation offset constant", SpotifyAudioHeader.normalisationOffset, 144)

        let withMagic = header(gains: gains, withOggMagic: true, trailingPadding: 32)
        if let parsed = SpotifyAudioHeader.parse(withMagic) {
            check.equal("trackGainDB", parsed.trackGainDB, gains[0])
            check.equal("trackPeak", parsed.trackPeak, gains[1])
            check.equal("albumGainDB", parsed.albumGainDB, gains[2])
            check.equal("albumPeak", parsed.albumPeak, gains[3])
        } else {
            check.check("header with valid magic parses", false)
        }
        check.check("hasOggCapture true when magic present", SpotifyAudioHeader.hasOggCapture(withMagic))

        let headerOnly = header(gains: gains, withOggMagic: false)
        check.notNil(
            "header without trailing bytes still parses (magic absent, not checked)",
            SpotifyAudioHeader.parse(headerOnly)
        )
        check.check(
            "hasOggCapture false when there are no trailing bytes",
            !SpotifyAudioHeader.hasOggCapture(headerOnly)
        )

        let tooShort = withMagic.prefix(SpotifyAudioHeader.length - 1)
        check.nil_("too-short prefix is nil", SpotifyAudioHeader.parse(Data(tooShort)))

        var wrongMagic = header(gains: gains, withOggMagic: false)
        wrongMagic.append(Data("XXXX".utf8))
        check.nil_("wrong magic is nil", SpotifyAudioHeader.parse(wrongMagic))
        check.check("hasOggCapture false for wrong magic", !SpotifyAudioHeader.hasOggCapture(wrongMagic))

        // A non-zero startIndex (e.g. a subrange of a larger buffer) must not misalign offsets.
        var padded = Data(repeating: 0xFF, count: 10)
        padded.append(withMagic)
        let offsetSlice = padded[padded.index(padded.startIndex, offsetBy: 10)...]
        if let parsed = SpotifyAudioHeader.parse(offsetSlice) {
            check.equal("non-zero startIndex trackGainDB", parsed.trackGainDB, gains[0])
        } else {
            check.check("header parses from a non-zero-startIndex slice", false)
        }
        check.check("hasOggCapture handles a non-zero-startIndex slice", SpotifyAudioHeader.hasOggCapture(offsetSlice))
    }
}
