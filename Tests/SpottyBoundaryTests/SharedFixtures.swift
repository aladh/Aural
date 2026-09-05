import Foundation
import SpottyDomain
@testable import SpottyCore

/// Shared dependencies for boundary checks that exercise a store while its external services are
/// intentionally idle. The account records authorization attempts because lifecycle checks use
/// that observation to distinguish recovery from interactive reauthentication.
final class BoundaryIdleAccount: AccountSession, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAuthorizeCount = 0

    var authorizeCount: Int {
        lock.withLock { storedAuthorizeCount }
    }

    func authorizeInteractively() async throws -> KeymasterTokens {
        lock.withLock { storedAuthorizeCount += 1 }
        throw CancellationError()
    }

    func hasGrant() async -> Bool { false }
    func accessToken() async throws -> String { "fixture-access" }
    func adopt(_: KeymasterTokens) async throws {}
    func clear() async {}
    func revocations() -> AsyncStream<Void> {
        AsyncStream { $0.finish() }
    }
}

struct BoundaryIdleLifecycle: SystemLifecycleEvents {
    func events() -> AsyncStream<SystemLifecycleEvent> {
        AsyncStream { $0.finish() }
    }
}

struct BoundaryIdleAudio: AudioOutputPreparing {
    func prepareForPlayback() throws {}
}

struct BoundaryIdleAttributes: TrackAttributesProviding {
    func attributes(for _: [String]) async throws -> [String: TrackAttributes] { [:] }
}

enum BoundaryFixtureFailure: Error {
    case unavailable
}

struct BoundaryIdleCatalog: CatalogProviding {
    func searchTracks(_: String, limit _: Int) async throws -> [PathfinderTrack] {
        throw BoundaryFixtureFailure.unavailable
    }

    func home() async throws -> PathfinderHome {
        throw BoundaryFixtureFailure.unavailable
    }

    func libraryPlaylists() async throws -> [PathfinderPlaylist] {
        throw BoundaryFixtureFailure.unavailable
    }

    func libraryAlbums() async throws -> [PathfinderAlbum] {
        throw BoundaryFixtureFailure.unavailable
    }

    func libraryArtists() async throws -> [PathfinderArtist] {
        throw BoundaryFixtureFailure.unavailable
    }

    func libraryTracks() async throws -> [PathfinderLibraryTrackItem] {
        throw BoundaryFixtureFailure.unavailable
    }

    func profile() async throws -> PathfinderProfile {
        throw BoundaryFixtureFailure.unavailable
    }

    func playlist(id _: String) async throws -> PathfinderPlaylistUnion {
        throw BoundaryFixtureFailure.unavailable
    }
}
