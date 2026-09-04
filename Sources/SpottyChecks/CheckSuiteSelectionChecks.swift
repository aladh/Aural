import SpottyCheckSelection
import Foundation

func runCheckSuiteSelectionChecks(_ check: CheckRunner, catalog: [String]) {
    let examples = ["alpha", "beta", "gamma"]

    check.suite("Check suite argument parsing") {
        expectRun(check, arguments: [], catalog: examples, expected: examples)
        expectCommand(check, "help long flag", arguments: ["--help"], catalog: examples, expected: .showHelp)
        expectCommand(check, "help short flag", arguments: ["-h"], catalog: examples, expected: .showHelp)
        expectCommand(check, "list long flag", arguments: ["--list"], catalog: examples, expected: .listSuites)
        expectCommand(check, "list short flag", arguments: ["-l"], catalog: examples, expected: .listSuites)
        expectRun(check, arguments: ["beta"], catalog: examples, expected: ["beta"])
        expectRun(
            check,
            arguments: ["gamma", "alpha"],
            catalog: examples,
            expected: ["gamma", "alpha"]
        )
        expectRun(
            check,
            arguments: ["alpha", "gamma", "alpha", "beta", "gamma"],
            catalog: examples,
            expected: ["alpha", "gamma", "beta"]
        )

        expectFailure(check, "empty suite name", arguments: [""], catalog: examples, matching: "empty")
        expectFailure(
            check,
            "unknown suite",
            arguments: ["delta"],
            catalog: examples,
            matching: "Unknown suite name: delta"
        )
        expectFailure(
            check,
            "unknown suites keep request order",
            arguments: ["delta", "alpha", "epsilon", "delta"],
            catalog: examples,
            matching: "Unknown suite names: delta, epsilon"
        )
        expectFailure(check, "unknown option", arguments: ["--quiet"], catalog: examples, matching: "Unknown option")
        expectFailure(
            check,
            "help and list together",
            arguments: ["--help", "--list"],
            catalog: examples,
            matching: "not both"
        )
        expectFailure(
            check,
            "help with suite names",
            arguments: ["--help", "alpha"],
            catalog: examples,
            matching: "alone"
        )
        expectFailure(
            check,
            "names are case-sensitive",
            arguments: ["Alpha"],
            catalog: examples,
            matching: "Unknown suite name: Alpha"
        )
    }

    check.suite("Check suite launch fails before running") {
        var output: [String] = []
        var errors: [String] = []
        var ran = false
        let launch = CheckSuiteLaunch.interpret(
            arguments: ["missing-suite"],
            catalog: examples,
            executableName: "SpottyChecks",
            printOutput: { output.append($0) },
            printError: { errors.append($0) }
        )
        if launch.suiteNames != nil {
            ran = true
        }
        check.nil_("unknown selection yields no suite list", launch.suiteNames)
        check.check("unknown selection is a usage failure", launch.failed)
        check.check("unknown selection does not run checks", !ran)
        check.equal("unknown selection prints nothing to stdout", output, [])
        check.check("unknown selection explains the failure", errors.contains { $0.contains("missing-suite") })

        output = []
        errors = []
        let emptyLaunch = CheckSuiteLaunch.interpret(
            arguments: [""],
            catalog: examples,
            executableName: "SpottyChecks",
            printOutput: { output.append($0) },
            printError: { errors.append($0) }
        )
        check.nil_("empty name yields no suite list", emptyLaunch.suiteNames)
        check.check("empty name is a usage failure", emptyLaunch.failed)
        check.equal("empty name prints nothing to stdout", output, [])
        check.check("empty name explains the failure", errors.contains { $0.contains("empty") })
    }

    check.suite("Registered check suites remain selectable") {
        check.check("registration names are unique", Set(catalog).count == catalog.count)
        check.check("registration names are not empty", catalog.allSatisfy { !$0.isEmpty })

        expectRun(check, arguments: [], catalog: catalog, expected: catalog)

        for name in catalog {
            expectRun(check, arguments: [name], catalog: catalog, expected: [name])
        }

        if catalog.count >= 2 {
            let reversed = Array(catalog.reversed())
            expectRun(check, arguments: reversed + [catalog[0]], catalog: catalog, expected: reversed)
        }

        let listed = CheckSuiteSelection.listText(catalog: catalog)
        check.equal("list output is registration order", listed.split(separator: "\n").map(String.init), catalog)
        check.check(
            "help names the executable",
            CheckSuiteSelection.helpText(executableName: "SpottyChecks").contains("SpottyChecks --list")
        )

        check.equal(
            "runProtobufChecks maps to protobuf",
            CheckSuiteRegistration.suiteName(fromRunFunction: "runProtobufChecks"),
            Optional("protobuf")
        )
        check.equal(
            "runURIChecks maps to uri",
            CheckSuiteRegistration.suiteName(fromRunFunction: "runURIChecks"),
            Optional("uri")
        )
        check.equal(
            "runPCMWriteSpaceChecks maps to pcm-write-space",
            CheckSuiteRegistration.suiteName(fromRunFunction: "runPCMWriteSpaceChecks"),
            Optional("pcm-write-space")
        )
        check.equal(
            "runMediaDetailStoreChecks maps to media-detail-store",
            CheckSuiteRegistration.suiteName(fromRunFunction: "runMediaDetailStoreChecks"),
            Optional("media-detail-store")
        )
        let sourceWithPhantomDeclarations = [
            "func runFirstRealChecks(_ check: CheckRunner) {}",
            "// func runLineCommentChecks(_ check: CheckRunner) {}",
            "// 🐈 func runUnicodeCommentChecks(_ check: CheckRunner) {}",
            "/* func runBlockCommentChecks(_ check: CheckRunner) {} */",
            "/* outer /* func runNestedCommentChecks(_ check: CheckRunner) {} */ */",
            #"let quoted = "func runQuotedStringChecks(_ check: CheckRunner) {}""#,
            "let multiline = \"\"\"",
            "func runMultilineStringChecks(_ check: CheckRunner) {}",
            "\"\"\"",
            "let raw = #\"func runRawStringChecks(_ check: CheckRunner) {}\"#",
            "func runLastRealChecks(_ check: CheckRunner) {}",
        ].joined(separator: "\n")
        check.equal(
            "comments and strings do not register phantom suites",
            CheckSuiteRegistration.runCheckFunctionNames(in: sourceWithPhantomDeclarations),
            ["runFirstRealChecks", "runLastRealChecks"]
        )
        check.equal(
            "an omitted run*Checks function is reported",
            CheckSuiteRegistration.namesMissingFromCatalog(
                catalog: ["alpha"],
                defined: ["alpha", "media-detail-store"]
            ),
            ["media-detail-store"]
        )

        check.noThrow("every compiled run*Checks function is registered") {
            let sources = try CheckSuiteRegistration.swiftSources(
                in: URL(fileURLWithPath: #filePath).deletingLastPathComponent(),
                excludingDirectoryNames: ["DeferredBoundaryChecks"]
            )
            let defined = CheckSuiteRegistration.expectedSuiteNames(fromSources: sources)
            check.equal(
                "defined run*Checks missing from the SpottyChecks registry",
                CheckSuiteRegistration.namesMissingFromCatalog(catalog: catalog, defined: defined),
                []
            )
            check.equal(
                "SpottyChecks registry names without a run*Checks function",
                CheckSuiteRegistration.namesMissingFromSources(catalog: catalog, defined: defined),
                []
            )
        }
    }
}

private func expectCommand(
    _ check: CheckRunner,
    _ label: String,
    arguments: [String],
    catalog: [String],
    expected: CheckSuiteCommand
) {
    switch CheckSuiteSelection.resolve(arguments: arguments, catalog: catalog) {
    case .success(let command):
        check.equal(label, command, expected)
    case .failure(let error):
        check.check("\(label): unexpected failure \(error)", false)
    }
}

private func expectRun(
    _ check: CheckRunner,
    arguments: [String],
    catalog: [String],
    expected: [String]
) {
    let label =
        arguments.isEmpty ? "no arguments run the full catalog" : "selection \(arguments.joined(separator: ", "))"
    expectCommand(check, label, arguments: arguments, catalog: catalog, expected: .runSuites(expected))
}

private func expectFailure(
    _ check: CheckRunner,
    _ label: String,
    arguments: [String],
    catalog: [String],
    matching: String
) {
    switch CheckSuiteSelection.resolve(arguments: arguments, catalog: catalog) {
    case .success(let command):
        check.check("\(label): expected failure, got \(command)", false)
    case .failure(let error):
        check.check("\(label): \(error.description)", error.description.contains(matching))
    }
}
