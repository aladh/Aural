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
        // Keep each UTF-16 source position intact so matches can still be converted against the
        // original source, while preventing examples in prose or string fixtures from registering
        // phantom suites.
        let searchableSource = sourceWithCommentsAndStringsMasked(source)
        let range = NSRange(searchableSource.startIndex..., in: searchableSource)
        return regex.matches(in: searchableSource, range: range).compactMap { match in
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
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
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

private func sourceWithCommentsAndStringsMasked(_ source: String) -> String {
    var units = Array(source.utf16)
    var index = 0

    func mask(_ offset: Int) {
        if units[offset] != 10, units[offset] != 13 {
            units[offset] = 32
        }
    }

    func maskRange(_ start: Int, _ end: Int) {
        guard start < end else {
            return
        }
        for offset in start..<end {
            mask(offset)
        }
    }

    while index < units.count {
        if units[index] == 47, index + 1 < units.count {
            if units[index + 1] == 47 {
                let start = index
                index += 2
                while index < units.count, units[index] != 10, units[index] != 13 {
                    index += 1
                }
                maskRange(start, index)
                continue
            }

            if units[index + 1] == 42 {
                let start = index
                var depth = 1
                index += 2
                while index < units.count, depth > 0 {
                    if index + 1 < units.count, units[index] == 47, units[index + 1] == 42 {
                        depth += 1
                        index += 2
                    } else if index + 1 < units.count, units[index] == 42, units[index + 1] == 47 {
                        depth -= 1
                        index += 2
                    } else {
                        index += 1
                    }
                }
                maskRange(start, index)
                continue
            }
        }

        let hashCount: Int
        let stringStart: Int
        if units[index] == 35 {
            var hashesEnd = index
            while hashesEnd < units.count, units[hashesEnd] == 35 {
                hashesEnd += 1
            }
            guard hashesEnd < units.count, units[hashesEnd] == 34 else {
                index = hashesEnd
                continue
            }
            hashCount = hashesEnd - index
            stringStart = index
            index = hashesEnd
        } else if units[index] == 34 {
            hashCount = 0
            stringStart = index
        } else {
            index += 1
            continue
        }

        let isMultiline = index + 2 < units.count && units[index + 1] == 34 && units[index + 2] == 34
        let quoteCount = isMultiline ? 3 : 1
        index += quoteCount

        while index < units.count {
            let hasClosingQuotes = (0..<quoteCount).allSatisfy { offset in
                index + offset < units.count && units[index + offset] == 34
            }
            let hashesStart = index + quoteCount
            let hasClosingHashes = (0..<hashCount).allSatisfy { offset in
                hashesStart + offset < units.count && units[hashesStart + offset] == 35
            }
            if hasClosingQuotes, hasClosingHashes {
                index = hashesStart + hashCount
                break
            }
            if hashCount == 0, !isMultiline, units[index] == 92 {
                index += min(2, units.count - index)
            } else {
                index += 1
            }
        }
        maskRange(stringStart, index)
    }

    return String(decoding: units, as: UTF16.self)
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
