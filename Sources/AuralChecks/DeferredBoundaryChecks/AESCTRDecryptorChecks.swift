import Foundation
@testable import AuralCore

@MainActor
func runAESCTRDecryptorChecks(_ check: CheckRunner) {
    check.suite("AES-128-CTR against NIST SP 800-38A F.5.1") {
        let key = hex("2b7e151628aed2a6abf7158809cf4f3c")
        let counter = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plaintext = hex(
            "6bc1bee22e409f96e93d7e117393172a"
                + "ae2d8a571e03ac9c9eb76fac45af8e51"
                + "30c81c46a35ce411e5fbc1191a0a52ef"
                + "f69f2445df4f9b17ad2b417be66c3710"
        )
        let ciphertext = hex(
            "874d6191b620e3261bef6864990db6ce"
                + "9806f66b7970fdff8617187bb9fffdff"
                + "5ae4df3edbd5d35e5b4f09020db03eab"
                + "1e031dda2fbe03d1792170a0f3009cee"
        )

        do {
            let decryptor = try AESCTRDecryptor(key: key, iv: counter)
            let decrypted = try decryptor.decrypt(Data(ciphertext))
            check.equal("NIST vector decrypts to the reference plaintext", decrypted, Data(plaintext))
        } catch {
            check.check("NIST vector decryption did not throw: \(error)", false)
        }
    }

    check.suite("seeking mid-stream matches decrypting the whole stream") {
        let key = hex("000102030405060708090a0b0c0d0e0f")
        let buffer = lcgBuffer(count: 4_096)

        guard let fullDecryptor = try? AESCTRDecryptor(key: key),
            let full = try? fullDecryptor.decrypt(Data(buffer))
        else {
            check.check("full-stream decryption did not throw", false)
            return
        }

        for offset in [1, 15, 16, 17, 1_000, 4_080] {
            guard let seeked = try? AESCTRDecryptor(key: key) else {
                check.check("decryptor \(offset) constructs", false)
                continue
            }
            do {
                try seeked.seek(toByteOffset: UInt64(offset))
                let suffixInput = Data(buffer[offset...])
                let suffixOutput = try seeked.decrypt(suffixInput)
                check.equal("seek(\(offset)) matches the full decrypt's suffix", suffixOutput, full[offset...])
            } catch {
                check.check("seek(\(offset)) did not throw: \(error)", false)
            }
        }
    }

    check.suite("seeking with a non-default IV uses that IV, not spotifyIV") {
        // A decryptor constructed with an explicit IV must fold *that* IV into the counter on
        // seek, not silently fall back to the Spotify default — otherwise a caller using a
        // non-default IV (as every check above except this one avoids) would seek to the wrong
        // keystream position with no error.
        let key = hex("101112131415161718191a1b1c1d1e1f")
        let customIV = hex("00000000000000000000000000000001")
            .suffix(16)
        let iv = Array(customIV)
        let buffer = lcgBuffer(count: 64)

        guard let fullDecryptor = try? AESCTRDecryptor(key: key, iv: iv),
            let full = try? fullDecryptor.decrypt(Data(buffer)),
            let seeked = try? AESCTRDecryptor(key: key, iv: iv)
        else {
            check.check("custom-IV decryptors construct and decrypt", false)
            return
        }
        do {
            try seeked.seek(toByteOffset: 16)
            let suffixOutput = try seeked.decrypt(Data(buffer[16...]))
            check.equal("seek with a custom IV matches that IV's full decrypt", suffixOutput, full[16...])
        } catch {
            check.check("seek with a custom IV did not throw: \(error)", false)
        }
    }

    check.suite("counter carry arithmetic") {
        let allFF = [UInt8](repeating: 0xFF, count: 16)
        check.equal(
            "iv all 0xff, block 1 carries all the way to zero",
            AESCTRDecryptor.counter(iv: allFF, block: 1),
            [UInt8](repeating: 0x00, count: 16)
        )

        var endingFF = [UInt8](repeating: 0x00, count: 16)
        endingFF[15] = 0xFF
        var expectedEnding = endingFF
        expectedEnding[14] = 0x01
        expectedEnding[15] = 0x00
        check.equal(
            "iv ending 00 ff, block 1 carries into the second-to-last byte",
            AESCTRDecryptor.counter(iv: endingFF, block: 1),
            expectedEnding
        )

        let zero = [UInt8](repeating: 0x00, count: 16)
        var expectedFromShift32 = zero
        expectedFromShift32[11] = 0x01
        check.equal(
            "block 1<<32 increments byte index 11",
            AESCTRDecryptor.counter(iv: zero, block: 1 << 32),
            expectedFromShift32
        )
    }
}

/// Decodes a hex string into bytes. Only used by checks, on trusted literal input.
private func hex(_ string: String) -> [UInt8] {
    var bytes: [UInt8] = []
    var chars = Array(string)
    precondition(chars.count % 2 == 0)
    while !chars.isEmpty {
        let pair = String(chars.prefix(2))
        chars.removeFirst(2)
        bytes.append(UInt8(pair, radix: 16)!)
    }
    return bytes
}

/// A small, deterministic pseudo-random buffer standing in for ciphertext bytes: the values
/// don't need to be "real" ciphertext, only the same across every call for a given `count`.
private func lcgBuffer(count: Int) -> [UInt8] {
    var state: UInt32 = 0x2545_F491
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    for _ in 0..<count {
        state = 1_664_525 &* state &+ 1_013_904_223
        bytes.append(UInt8(truncatingIfNeeded: state >> 24))
    }
    return bytes
}
