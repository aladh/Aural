import Foundation

/// Maps `run*Checks` entry points onto the kebab-case names used for suite selection.
public enum CheckSuiteRegistration {
    public static func suiteName(fromRunFunction functionName: String) -> String? {
        let prefix = "run"
        let suffix = "Checks"
        guard functionName.hasPrefix(prefix), functionName.hasSuffix(suffix) else {
            return nil
        }
        let stem = String(functionName.dropFirst(prefix.count).dropLast(suffix.count))
        guard !stem.isEmpty else {
            return nil
        }
        return kebabCase(stem)
    }

    public static func runCheckFunctionNames(in source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\bfunc (run[A-Za-z0-9]+Checks)\s*\("#) else {
            return []
        }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let functionRange = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[functionRange])
        }
    }

    public static func expectedSuiteNames(fromSources sources: [String]) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        for source in sources {
            for functionName in runCheckFunctionNames(in: source) {
                guard let name = suiteName(fromRunFunction: functionName) else {
                    continue
                }
                if seen.insert(name).inserted {
                    names.append(name)
                }
            }
        }
        return names
    }

    public static func namesMissingFromCatalog(catalog: [String], defined: [String]) -> [String] {
        let catalogSet = Set(catalog)
        return defined.filter { !catalogSet.contains($0) }
    }

    public static func namesMissingFromSources(catalog: [String], defined: [String]) -> [String] {
        let definedSet = Set(defined)
        return catalog.filter { !definedSet.contains($0) }
    }

    public static func swiftSources(
        in directory: URL,
        excludingDirectoryNames: Set<String> = [],
        excludingFileNames: Set<String> = []
    ) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            let name = item.lastPathComponent
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory, excludingDirectoryNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            guard item.pathExtension == "swift" else {
                continue
            }
            guard !excludingFileNames.contains(name) else {
                continue
            }
            files.append(item)
        }

        files.sort { $0.path < $1.path }
        return try files.map { try String(contentsOf: $0, encoding: .utf8) }
    }
}

private func kebabCase(_ identifier: String) -> String {
    let pattern = #"[A-Z]+(?=[A-Z][a-z])|[A-Z][a-z]+|[A-Z]+|[a-z]+|[0-9]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
        return identifier.lowercased()
    }
    let range = NSRange(identifier.startIndex..., in: identifier)
    return regex.matches(in: identifier, range: range).compactMap { match -> String? in
        guard let partRange = Range(match.range, in: identifier) else {
            return nil
        }
        return String(identifier[partRange]).lowercased()
    }.joined(separator: "-")
}
