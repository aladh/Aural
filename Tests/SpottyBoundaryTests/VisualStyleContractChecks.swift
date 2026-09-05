import Testing
import SpottyDomain
import Foundation
@testable import SpottyCore

@Suite("Visual Style Contract")
struct VisualStyleContractTests {
    @Test
    @MainActor
    func testVisualStyleContract() {
        do {
            #expect((homeSectionPresentation(at: 0)) == (.quickAccess), "the leading Home section is quick access")
            #expect((homeSectionPresentation(at: 1)) == (.shelf), "the second Home section stays a shelf")
            #expect((homeSectionPresentation(at: 8)) == (.shelf), "later Home sections stay shelves")

            let remote = PlaybackDevice(id: "speaker", name: "Kitchen", type: "speaker", isActive: true)
            let local = PlaybackDevice(id: "mac", name: "This Mac", type: "computer", isActive: true)
            let confirmed = remotePlaybackBannerPresentation(
                phase: .ready,
                owner: .remote(remote),
                hasCurrentTrack: true,
                isPlaying: true
            )
            #expect((confirmed?.device.name) == ("Kitchen"), "confirmed remote playback names its device")
            #expect((confirmed?.isPlaying) == (true), "confirmed remote playback carries transport state")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .remote(remote),
                    hasCurrentTrack: true,
                    isPlaying: false
                )?.isPlaying) == (false), "confirmed paused remote playback remains visible")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .uncertain(remote),
                    hasCurrentTrack: true,
                    isPlaying: false
                )) == nil, "an uncertain remembered route does not claim remote playback")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .uncertain(nil),
                    hasCurrentTrack: true,
                    isPlaying: false
                )) == nil, "an unidentified uncertain owner has no remote banner")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .local(local),
                    hasCurrentTrack: true,
                    isPlaying: true
                )) == nil, "local playback has no remote banner")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .ready,
                    owner: .remote(remote),
                    hasCurrentTrack: false,
                    isPlaying: false
                )) == nil, "remote ownership without a current track has no banner")
            #expect(
                (remotePlaybackBannerPresentation(
                    phase: .recovering,
                    owner: .remote(remote),
                    hasCurrentTrack: true,
                    isPlaying: true
                )) == nil, "recovering playback does not make a stale remote claim")

        }
    }
}
