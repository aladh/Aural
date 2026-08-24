import AppKit
import Foundation
import ImageIO

/// A bounded, downsampling image cache for album and playlist artwork.
///
/// Spotify artwork is commonly much larger than the 28–184 point surfaces used by Aural.
/// Decoding the originals through `AsyncImage` retains full-size backing stores and lets the
/// shared URL cache grow independently. This cache caps both layers and decodes only the pixels
/// the interface can display on a Retina screen.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()

    private let images = NSCache<NSString, NSImage>()
    private let session: URLSession
    private var inFlight: [NSString: Task<NSImage?, Never>] = [:]
    /// Failed fetches retry after this long instead of on every appearance.
    private let failureRetryInterval: TimeInterval = 20
    /// Broken or expired artwork URLs must not accumulate for an entire listening session.
    private static let failureCacheLimit = 256
    private var failedAt: [NSString: Date] = [:]

    private init() {
        images.countLimit = 96
        images.totalCostLimit = 24 * 1_024 * 1_024

        // Artwork is already downsampled into a bounded NSCache below. A second on-disk cache
        // adds SQLite work and can outlive Spotify's signed artwork URLs, so keep only a small
        // response cache for duplicate requests within the current app session.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = URLCache(
            memoryCapacity: 4 * 1_024 * 1_024,
            diskCapacity: 0,
            diskPath: nil
        )
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    func image(for url: URL, pointSize: CGFloat) async -> NSImage? {
        let pixelSize = Self.pixelBucket(for: pointSize)
        let key = "\(url.absoluteString)#\(pixelSize)" as NSString

        if let cached = images.object(forKey: key) {
            return cached
        }
        // A recently failed fetch waits out its TTL rather than hammering the network
        // once per recycled row.
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < failureRetryInterval {
            return nil
        }
        if let task = inFlight[key] {
            return await task.value
        }

        let task = Task { [session] () -> NSImage? in
            do {
                let (data, response) = try await session.data(from: url)
                guard
                    !Task.isCancelled,
                    (response as? HTTPURLResponse).map({ 200..<300 ~= $0.statusCode }) ?? true
                else { return nil }

                guard let decoded = await Task.detached(priority: .utility, operation: {
                    Self.downsample(data, maxPixelSize: pixelSize)
                }).value else { return nil }

                return NSImage(
                    cgImage: decoded.image,
                    size: NSSize(width: decoded.image.width, height: decoded.image.height)
                )
            } catch {
                return nil
            }
        }

        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image, let representation = image.representations.first {
            let cost = representation.pixelsWide * representation.pixelsHigh * 4
            images.setObject(image, forKey: key, cost: cost)
            failedAt[key] = nil
        } else if !Task.isCancelled {
            let now = Date()
            failedAt = failedAt.filter { now.timeIntervalSince($0.value) < failureRetryInterval }
            if failedAt.count >= Self.failureCacheLimit {
                failedAt.removeAll(keepingCapacity: true)
            }
            failedAt[key] = now
        }
        return image
    }

    /// Drops every cached image and cancels in-flight fetches. Views release their own strong
    /// image references on disappearance and refetch through their normal task on reappearance.
    func removeAll() {
        inFlight.values.forEach { $0.cancel() }
        inFlight.removeAll(keepingCapacity: false)
        failedAt.removeAll(keepingCapacity: false)
        images.removeAllObjects()
        session.configuration.urlCache?.removeAllCachedResponses()
    }

    private nonisolated static func pixelBucket(for pointSize: CGFloat) -> Int {
        let requested = max(64, Int((pointSize * 2).rounded(.up)))
        return [64, 128, 256, 384, 512].first { $0 >= requested } ?? 512
    }

    private nonisolated static func downsample(_ data: Data, maxPixelSize: Int) -> SendableCGImage? {
        autoreleasepool {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                .map(SendableCGImage.init)
        }
    }
}

private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}
