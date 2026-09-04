import SpottyCheckSelection
import Foundation

@MainActor
func runCheckSuiteSelectionChecks(_ check: CheckRunner, catalog: [String]) {
    check.suite("Registered check suites remain selectable") {
        check.check("registration names are unique", Set(catalog).count == catalog.count)
        check.check("registration names are not empty", catalog.allSatisfy { !$0.isEmpty })

        switch CheckSuiteSelection.resolve(arguments: [], catalog: catalog) {
        case .success(.runSuites(let names)):
            check.equal("no arguments run the full catalog once", names, catalog)
        case .success(let command):
            check.check("no arguments should run suites, got \(command)", false)
        case .failure(let error):
            check.check("no arguments unexpected failure \(error)", false)
        }

        for name in catalog {
            switch CheckSuiteSelection.resolve(arguments: [name], catalog: catalog) {
            case .success(.runSuites(let names)):
                check.equal("\(name) remains selectable", names, [name])
            case .success(let command):
                check.check("\(name) should run, got \(command)", false)
            case .failure(let error):
                check.check("\(name) unexpected failure \(error)", false)
            }
        }

        var output: [String] = []
        let launch = CheckSuiteLaunch.interpret(
            arguments: ["missing-suite"],
            catalog: catalog,
            executableName: "SpottyBoundaryChecks",
            printOutput: { output.append($0) },
            printError: { _ in }
        )
        check.nil_("unknown selection yields no suite list", launch.suiteNames)
        check.check("unknown selection is a usage failure", launch.failed)
        check.equal("unknown selection prints nothing to stdout", output, [])
        check.equal(
            "list output is registration order",
            CheckSuiteSelection.listText(catalog: catalog).split(separator: "\n").map(String.init),
            catalog
        )

        check.noThrow("every compiled run*Checks function is registered") {
            let sources = try CheckSuiteRegistration.swiftSources(
                in: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            )
            let defined = CheckSuiteRegistration.expectedSuiteNames(fromSources: sources)
            check.equal(
                "defined run*Checks missing from the SpottyBoundaryChecks registry",
                CheckSuiteRegistration.namesMissingFromCatalog(catalog: catalog, defined: defined),
                []
            )
            check.equal(
                "SpottyBoundaryChecks registry names without a run*Checks function",
                CheckSuiteRegistration.namesMissingFromSources(catalog: catalog, defined: defined),
                []
            )
        }
    }
}
