import Foundation

func boundaryFixture(
    named name: String,
    extension fileExtension: String = "json",
    subdirectory: String = "Fixtures"
) throws -> Data {
    guard
        let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        )
    else {
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}
