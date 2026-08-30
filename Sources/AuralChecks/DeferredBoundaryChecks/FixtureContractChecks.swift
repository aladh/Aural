import Foundation
@testable import AuralCore

@MainActor
func runFixtureContractChecks(_ check: CheckRunner) {
    check.suite("Sanitized Pathfinder response contracts") {
        let decoder = JSONDecoder()

        check.noThrow("track search fixture decodes") {
            let response = try decoder.decode(
                PathfinderResponse<PathfinderTrackResults>.self,
                from: boundaryFixture(named: "search-tracks")
            )
            check.equal("track wrapper shape", response.results?.tracksV2?.entities.first?.name, "Fixture Track")
        }
        check.noThrow("album fixture decodes") {
            let response = try decoder.decode(PathfinderAlbumResponse.self, from: boundaryFixture(named: "album"))
            check.equal("album track shape", response.data?.albumUnion?.tracks.first?.name, "Fixture Track")
        }
        check.noThrow("artist fixture decodes") {
            let response = try decoder.decode(PathfinderArtistResponse.self, from: boundaryFixture(named: "artist"))
            check.equal("discography group shape", response.data?.artistUnion?.releases.first?.name, "Fixture Album")
        }
        check.noThrow("home fixture decodes") {
            let response = try decoder.decode(PathfinderHomeResponse.self, from: boundaryFixture(named: "home"))
            check.equal("home section shape", response.home?.sections.first?.title, "Fixture shelf")
        }
    }
}
