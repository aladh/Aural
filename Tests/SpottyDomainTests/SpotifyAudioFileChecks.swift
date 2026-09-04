import Testing
//
//  SpotifyAudioFileChecks.swift
//  Spotty
//

import SpottyDomain
import Foundation

@Suite("Spotify Audio File")
struct SpotifyAudioFileTests {
    @Test
    func testSpotifyAudioFile() {
        do {
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
                #expect((format.kilobitsPerSecond) == (kbps), "\(format) kilobitsPerSecond")
                #expect((format.bytesPerSecond) == (kbps.map { $0 / 8 * 1024 }), "\(format) bytesPerSecond")
            }

            for format: SpotifyAudioFormat in [.oggVorbis96, .oggVorbis160, .oggVorbis320] {
                #expect((format.isOggVorbis) == true, "\(format) isOggVorbis")
            }
            for format: SpotifyAudioFormat in [
                .mp3_256, .mp3_320, .mp3_160, .mp3_96, .mp3_160Enc, .aac24, .aac48, .flac,
            ] {
                #expect((!format.isOggVorbis) == true, "\(format) is not Ogg Vorbis")
            }

            #expect((SpotifyAudioFormat.oggVorbis96.rawValue) == (0), "librespot raw value: oggVorbis96")
            #expect((SpotifyAudioFormat.mp3_256.rawValue) == (3), "librespot raw value: mp3_256")
            #expect((SpotifyAudioFormat.aac48.rawValue) == (9), "librespot raw value: aac48")
            #expect((SpotifyAudioFormat.flac.rawValue) == (16), "librespot raw value: flac")
        }

        do {
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

            #expect((SpotifyAudioHeader.length) == (0xa7), "header length constant")
            #expect((SpotifyAudioHeader.normalisationOffset) == (144), "normalisation offset constant")

            let withMagic = header(gains: gains, withOggMagic: true, trailingPadding: 32)
            if let parsed = SpotifyAudioHeader.parse(withMagic) {
                #expect((parsed.trackGainDB) == (gains[0]), "trackGainDB")
                #expect((parsed.trackPeak) == (gains[1]), "trackPeak")
                #expect((parsed.albumGainDB) == (gains[2]), "albumGainDB")
                #expect((parsed.albumPeak) == (gains[3]), "albumPeak")
            } else {
                #expect((false) == true, "header with valid magic parses")
            }
            #expect((SpotifyAudioHeader.hasOggCapture(withMagic)) == true, "hasOggCapture true when magic present")

            let headerOnly = header(gains: gains, withOggMagic: false)
            #expect(
                (SpotifyAudioHeader.parse(headerOnly)) != nil,
                "header without trailing bytes still parses (magic absent, not checked)")
            #expect(
                (!SpotifyAudioHeader.hasOggCapture(headerOnly)) == true,
                "hasOggCapture false when there are no trailing bytes")

            let tooShort = withMagic.prefix(SpotifyAudioHeader.length - 1)
            #expect((SpotifyAudioHeader.parse(Data(tooShort))) == nil, "too-short prefix is nil")

            var wrongMagic = header(gains: gains, withOggMagic: false)
            wrongMagic.append(Data("XXXX".utf8))
            #expect((SpotifyAudioHeader.parse(wrongMagic)) == nil, "wrong magic is nil")
            #expect((!SpotifyAudioHeader.hasOggCapture(wrongMagic)) == true, "hasOggCapture false for wrong magic")

            // A non-zero startIndex (e.g. a subrange of a larger buffer) must not misalign offsets.
            var padded = Data(repeating: 0xFF, count: 10)
            padded.append(withMagic)
            let offsetSlice = padded[padded.index(padded.startIndex, offsetBy: 10)...]
            if let parsed = SpotifyAudioHeader.parse(offsetSlice) {
                #expect((parsed.trackGainDB) == (gains[0]), "non-zero startIndex trackGainDB")
            } else {
                #expect((false) == true, "header parses from a non-zero-startIndex slice")
            }
            #expect(
                (SpotifyAudioHeader.hasOggCapture(offsetSlice)) == true,
                "hasOggCapture handles a non-zero-startIndex slice"
            )
        }
    }
}
