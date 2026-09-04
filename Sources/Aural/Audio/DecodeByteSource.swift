//
//  DecodeByteSource.swift
//  Aural
//
//  The decode pipeline's input seam. A later slice adapts the CDN range fetcher plus AES-CTR
//  decryptor to this; checks use a fake. Kept minimal -- the pipeline only ever needs a byte
//  range and (optionally) the total length, never the resolve/fetch/decrypt detail behind it.
//

import Foundation

/// A random-access, byte-range view over one decrypted track's bytes.
///
/// `read` may be called from `VorbisDecodePipeline`'s dedicated decode thread; conformers must
/// tolerate being awaited from a plain `Thread`, not just from structured Swift concurrency (see
/// `VorbisDecodePipeline.blockingRead`, which bridges the two).
protocol DecodeByteSource: Sendable {
    /// Reads up to `length` bytes starting at `offset`. May return fewer bytes than requested
    /// only at end of file; the pipeline treats a short read there as exhaustion.
    func read(offset: Int, length: Int) async throws -> Data

    /// The total byte length of the track, if known up front.
    var length: Int? { get async }
}
