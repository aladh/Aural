//
//  AESCTRDecryptor.swift
//  Aural
//
//  Decrypts a Spotify CDN audio file: AES-128 in CTR mode with a fixed IV and the byte offset
//  folded into the counter, so any byte range of the file can be decrypted without replaying
//  the stream from the start.
//

import CommonCrypto
import Foundation

public enum AESCTRError: Error, Sendable {
    case invalidKeyLength
    case invalidIVLength
    case cryptorCreationFailed(CCCryptorStatus)
    case cryptorUpdateFailed(CCCryptorStatus)
}

/// AES-128-CTR decryption for Spotify's CDN file encryption. Spotify encrypts every file with
/// the same IV; only the per-file key (fetched separately) varies. Because CTR is a stream
/// cipher, decrypting an arbitrary byte range only requires advancing the counter to the right
/// block and discarding the leftover keystream bytes within that block — `seek(toByteOffset:)`
/// does exactly that, which is what makes ranged CDN fetches (`RangedAudioFetcher`) useful.
public final class AESCTRDecryptor {
    /// The IV Spotify uses for every encrypted file, taken from librespot.
    public static let spotifyIV: [UInt8] = [
        0x72, 0xe0, 0x67, 0xfb, 0xdd, 0xcb, 0xcf, 0x77,
        0xeb, 0xe8, 0xbc, 0x64, 0x3f, 0x63, 0x0d, 0x93,
    ]

    private let key: [UInt8]
    private let iv: [UInt8]
    private var cryptor: CCCryptorRef?

    public init(key: [UInt8], iv: [UInt8] = spotifyIV) throws {
        guard key.count == kCCKeySizeAES128 else { throw AESCTRError.invalidKeyLength }
        guard iv.count == kCCBlockSizeAES128 else { throw AESCTRError.invalidIVLength }
        self.key = key
        self.iv = iv
        try Self.createCryptor(counter: iv, key: key, into: &cryptor)
    }

    deinit {
        if let cryptor {
            CCCryptorRelease(cryptor)
        }
    }

    /// Repositions decryption to `offset` bytes into the plaintext stream. Recreates the
    /// underlying cryptor at the containing block's counter value, then discards the keystream
    /// bytes before `offset` within that block so the next `update` starts exactly at `offset`.
    public func seek(toByteOffset offset: UInt64) throws {
        let blockSize = UInt64(kCCBlockSizeAES128)
        let block = offset / blockSize
        let leftover = Int(offset % blockSize)

        let counter = Self.counter(iv: iv, block: block)
        try Self.createCryptor(counter: counter, key: key, into: &cryptor)

        guard leftover > 0 else { return }
        let discardIn = [UInt8](repeating: 0, count: leftover)
        var discardOut = [UInt8](repeating: 0, count: leftover)
        var moved = 0
        let status = discardIn.withUnsafeBytes { inBytes in
            discardOut.withUnsafeMutableBytes { outBytes in
                CCCryptorUpdate(
                    cryptor,
                    inBytes.baseAddress,
                    inBytes.count,
                    outBytes.baseAddress,
                    outBytes.count,
                    &moved
                )
            }
        }
        guard status == kCCSuccess else { throw AESCTRError.cryptorUpdateFailed(status) }
    }

    /// Decrypts (equivalently, encrypts — CTR is symmetric) `input` into `output`, which must be
    /// at least as large as `input`. Returns the number of bytes written.
    public func update(_ input: UnsafeRawBufferPointer, into output: UnsafeMutableRawBufferPointer) throws -> Int {
        var moved = 0
        let status = CCCryptorUpdate(
            cryptor,
            input.baseAddress,
            input.count,
            output.baseAddress,
            output.count,
            &moved
        )
        guard status == kCCSuccess else { throw AESCTRError.cryptorUpdateFailed(status) }
        return moved
    }

    /// Convenience wrapper around `update(_:into:)` for callers that already have the whole
    /// buffer in memory.
    public func decrypt(_ data: Data) throws -> Data {
        var output = Data(count: data.count)
        let moved = try data.withUnsafeBytes { inBytes in
            try output.withUnsafeMutableBytes { outBytes in
                try update(inBytes, into: outBytes)
            }
        }
        output.removeSubrange(moved..<output.count)
        return output
    }

    /// The 128-bit big-endian CTR counter for `block`: `iv` treated as a big-endian integer,
    /// plus `block`, carrying across all 16 bytes. Kept as a pure, independently checkable
    /// helper because the carry arithmetic is the one genuinely fiddly part of this file.
    public static func counter(iv: [UInt8], block: UInt64) -> [UInt8] {
        var counter = iv
        var carry = block
        var index = counter.count - 1
        while carry > 0, index >= 0 {
            let sum = UInt64(counter[index]) + (carry & 0xFF)
            counter[index] = UInt8(sum & 0xFF)
            carry = (carry >> 8) + (sum >> 8)
            index -= 1
        }
        return counter
    }

    private static func createCryptor(counter: [UInt8], key: [UInt8], into cryptor: inout CCCryptorRef?) throws {
        if let existing = cryptor {
            CCCryptorRelease(existing)
            cryptor = nil
        }
        let status = CCCryptorCreateWithMode(
            CCOperation(kCCEncrypt),
            CCMode(kCCModeCTR),
            CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding),
            counter,
            key,
            key.count,
            nil,
            0,
            0,
            CCModeOptions(kCCModeOptionCTR_BE),
            &cryptor
        )
        guard status == kCCSuccess else { throw AESCTRError.cryptorCreationFailed(status) }
    }
}
