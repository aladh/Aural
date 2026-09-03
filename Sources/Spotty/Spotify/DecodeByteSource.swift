//
//  DecodeByteSource.swift
//  Spotty
//
//  The decode pipeline's input seam. A later slice adapts the CDN fetcher plus AES-CTR decryptor
//  to this; checks use a fake. Kept minimal -- the pipeline only ever needs a byte range and
//  (optionally) the total length, never the resolve/fetch/decrypt detail behind it.
//
//  Synchronous by design: `VorbisDecodePipeline` only ever calls this from its own dedicated
//  decode thread, which exists precisely so it is free to block. A conformer owns its own
//  timeouts/retries and should not need an async bridge just to satisfy this seam.
//

import Foundation

/// A random-access, byte-range view over one decrypted track's bytes.
///
/// `read` is called only from `VorbisDecodePipeline`'s dedicated decode thread, never the main
/// actor -- a conformer must be safe to block that one background thread.
protocol DecodeByteSource: Sendable {
    /// Reads up to `length` bytes starting at `offset`. May return fewer bytes than requested
    /// only at end of file; the pipeline treats a short read there as exhaustion.
    func read(offset: Int, length: Int) throws -> Data

    /// The total byte length of the track, if known up front.
    var length: Int? { get }
}
