import Foundation

/// Shared CLI policy for `AuralChecks` and `AuralBoundaryChecks`.
///
/// This is only the argument and suite-selection rules. It is not a shared
/// `CheckRunner`, wait helper, or generic check library.
public enum CheckSuiteCommand: Equatable, Sendable {
    case showHelp
    case listSuites
    case runSuites([String])
}

public enum CheckSuiteSelectionError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptySuiteName
    case unknownSuiteNames([String], catalog: [String])
    case unknownOption(String)
    case combinedHelpAndList
    case extraArgumentsWithHelpOrList

    public var description: String {
        switch self {
        case .emptySuiteName:
            return "Suite name must not be empty."
        case let .unknownSuiteNames(names, catalog):
            let unknown = names.joined(separator: ", ")
            let available = catalog.joined(separator: ", ")
            let noun = names.count == 1 ? "name" : "names"
            return "Unknown suite \(noun): \(unknown). Registered suites: \(available)."
        case let .unknownOption(option):
            return "Unknown option: \(option)."
        case .combinedHelpAndList:
            return "Pass --help or --list, not both."
        case .extraArgumentsWithHelpOrList:
            return "Pass --help or --list alone, without suite names."
        }
    }
}

public enum CheckSuiteSelection {
    public static func resolve(
        arguments: [String],
        catalog: [String]
    ) -> Result<CheckSuiteCommand, CheckSuiteSelectionError> {
        if arguments.contains(where: \.isEmpty) {
            return .failure(.emptySuiteName)
        }

        var wantsHelp = false
        var wantsList = false
        var suiteNames: [String] = []

        for argument in arguments {
            switch argument {
            case "-h", "--help":
                wantsHelp = true
            case "-l", "--list":
                wantsList = true
            default:
                if argument.hasPrefix("-") {
                    return .failure(.unknownOption(argument))
                }
                suiteNames.append(argument)
            }
        }

        if wantsHelp && wantsList {
            return .failure(.combinedHelpAndList)
        }
        if (wantsHelp || wantsList) && !suiteNames.isEmpty {
            return .failure(.extraArgumentsWithHelpOrList)
        }
        if wantsHelp {
            return .success(.showHelp)
        }
        if wantsList {
            return .success(.listSuites)
        }
        if suiteNames.isEmpty {
            return .success(.runSuites(catalog))
        }

        let catalogSet = Set(catalog)
        var unknown: [String] = []
        var seenUnknown = Set<String>()
        for name in suiteNames where !catalogSet.contains(name) {
            if seenUnknown.insert(name).inserted {
                unknown.append(name)
            }
        }
        if !unknown.isEmpty {
            return .failure(.unknownSuiteNames(unknown, catalog: catalog))
        }

        return .success(.runSuites(uniquePreservingOrder(suiteNames)))
    }

    public static func helpText(executableName: String) -> String {
        """
        Usage:
          \(executableName)
          \(executableName) --help
          \(executableName) --list
          \(executableName) <suite> [<suite> ...]

        With no arguments, every registered suite runs once in registration order.
        Pass suite names to run a subset. Names are exact and case-sensitive.
        Repeated names run once, in the first requested order.
        Unknown or empty names fail before any check runs.

        Options:
          -h, --help   Show this help
          -l, --list   Print registered suite names in registration order
        """
    }

    public static func listText(catalog: [String]) -> String {
        catalog.joined(separator: "\n")
    }
}

/// Interprets CLI arguments for a check executable without running suites.
public struct CheckSuiteLaunch: Equatable, Sendable {
    public var suiteNames: [String]?
    public var failed: Bool

    public static func interpret(
        arguments: [String],
        catalog: [String],
        executableName: String,
        printOutput: (String) -> Void,
        printError: (String) -> Void
    ) -> CheckSuiteLaunch {
        switch CheckSuiteSelection.resolve(arguments: arguments, catalog: catalog) {
        case .success(.showHelp):
            printOutput(CheckSuiteSelection.helpText(executableName: executableName))
            return CheckSuiteLaunch(suiteNames: nil, failed: false)
        case .success(.listSuites):
            printOutput(CheckSuiteSelection.listText(catalog: catalog))
            return CheckSuiteLaunch(suiteNames: nil, failed: false)
        case .success(.runSuites(let names)):
            return CheckSuiteLaunch(suiteNames: names, failed: false)
        case .failure(let error):
            printError(error.description)
            printError("Use \(executableName) --help to list options, or --list for suite names.")
            return CheckSuiteLaunch(suiteNames: nil, failed: true)
        }
    }
}

private func uniquePreservingOrder(_ names: [String]) -> [String] {
    var seen = Set<String>()
    var ordered: [String] = []
    for name in names where seen.insert(name).inserted {
        ordered.append(name)
    }
    return ordered
}

public func writeCheckSelectionError(_ message: String) {
    var line = message
    if !line.hasSuffix("\n") {
        line.append("\n")
    }
    FileHandle.standardError.write(Data(line.utf8))
}
