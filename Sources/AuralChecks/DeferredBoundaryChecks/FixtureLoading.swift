import Foundation

func boundaryFixture(named name: String, subdirectory: String = "Fixtures") throws -> Data {
    guard
        let url = Bundle.module.url(
            forResource: name,
            withExtension: "json",
            subdirectory: subdirectory
        )
    else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}
