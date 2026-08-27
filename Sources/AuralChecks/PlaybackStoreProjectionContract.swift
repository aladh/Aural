import Foundation

/// Declaration-aware contract for PlaybackStore presentation projections.
///
/// Writable computed properties on `PlaybackStore` recreate partial-presentation states that
/// the reducer boundary exists to prevent. The check is structure-aware: it walks type and
/// extension bodies rather than a source line range, so unrelated `func set…` methods and
/// setters on other types are not flagged.
enum PlaybackStoreProjectionContract {
    static let requiredReadOnlyProjections = [
        "phase",
        "trackURI",
        "isPlaying",
        "position",
        "statusText",
    ]

    static func writableComputedProperties(in source: String) -> [String] {
        playbackStoreTypeBodies(in: source).flatMap { writableComputedProperties(inTypeBody: $0) }
    }

    static func computedProperties(in source: String) -> [String] {
        playbackStoreTypeBodies(in: source).flatMap { computedProperties(inTypeBody: $0) }
    }

    static func liveSources(from playbackStorePath: String) -> [String] {
        let file = URL(fileURLWithPath: playbackStorePath)
        let directory = file.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [file.lastPathComponent]
        return names
            .filter { $0.hasPrefix("PlaybackStore") && $0.hasSuffix(".swift") }
            .sorted()
            .compactMap { try? String(contentsOf: directory.appendingPathComponent($0), encoding: .utf8) }
    }
}

private func playbackStoreTypeBodies(in source: String) -> [String] {
    let scalars = Array(source)
    var bodies: [String] = []
    var index = 0
    while index < scalars.count {
        guard let next = skipTrivia(scalars, from: index) else { break }
        index = next
        if let header = matchPlaybackStoreTypeStart(scalars, from: index) {
            guard let open = skipToOpeningBrace(scalars, from: header), scalars[open] == "{" else {
                index = header
                continue
            }
            guard let close = matchingBrace(scalars, opening: open) else { break }
            let innerStart = scalars.index(after: open)
            bodies.append(String(scalars[innerStart..<close]))
            index = close + 1
            continue
        }
        if let word = identifier(at: index, in: scalars) {
            index = word.upperBound
        } else {
            index += 1
        }
    }
    return bodies
}

private func matchPlaybackStoreTypeStart(_ scalars: [Character], from start: Int) -> Int? {
    var index = start
    while index < scalars.count {
        if let next = skipTrivia(scalars, from: index) {
            index = next
        }
        guard let word = identifier(at: index, in: scalars) else { return nil }
        let name = String(scalars[word])
        var cursor = word.upperBound
        if name == "final" || name == "public" || name == "internal" || name == "private" || name == "open" {
            guard let next = skipTrivia(scalars, from: cursor) else { return nil }
            index = next
            continue
        }
        guard name == "class" || name == "extension" else { return nil }
        guard let afterKeyword = skipTrivia(scalars, from: cursor) else { return nil }
        guard let typeName = identifier(at: afterKeyword, in: scalars) else { return nil }
        guard String(scalars[typeName]) == "PlaybackStore" else { return nil }
        return typeName.upperBound
    }
    return nil
}

private func writableComputedProperties(inTypeBody body: String) -> [String] {
    computedMembers(inTypeBody: body).compactMap { $0.hasSetter ? $0.name : nil }
}

private func computedProperties(inTypeBody body: String) -> [String] {
    computedMembers(inTypeBody: body).map(\.name)
}

private struct ComputedMember {
    var name: String
    var hasSetter: Bool
}

private func computedMembers(inTypeBody body: String) -> [ComputedMember] {
    let scalars = Array(body)
    var members: [ComputedMember] = []
    var index = 0
    var depth = 0
    while index < scalars.count {
        if let next = skipTrivia(scalars, from: index) {
            index = next
        }
        guard index < scalars.count else { break }
        let char = scalars[index]
        if char == "{" {
            depth += 1
            index += 1
            continue
        }
        if char == "}" {
            depth -= 1
            index += 1
            continue
        }
        if depth != 0 {
            index += 1
            continue
        }
        if let word = identifier(at: index, in: scalars) {
            let token = String(scalars[word])
            if token == "func" || token == "init" || token == "subscript" || token == "typealias" {
                index = skipSignatureToBodyEnd(scalars, from: word.upperBound) ?? (word.upperBound + 1)
                continue
            }
            if token == "var" {
                if let member = parseComputedVar(scalars, from: word.upperBound) {
                    members.append(member.member)
                    index = member.end
                    continue
                }
                index = word.upperBound
                continue
            }
            index = word.upperBound
            continue
        }
        index += 1
    }
    return members
}

private func parseComputedVar(_ scalars: [Character], from afterVar: Int) -> (member: ComputedMember, end: Int)? {
    guard let nameStart = skipTrivia(scalars, from: afterVar),
          let nameRange = identifier(at: nameStart, in: scalars)
    else { return nil }
    let name = String(scalars[nameRange])
    guard let afterName = skipTrivia(scalars, from: nameRange.upperBound) else { return nil }
    guard let bodyOpen = skipTypeAnnotationToBodyOrAssignment(scalars, from: afterName) else { return nil }
    if scalars[bodyOpen] == "=" {
        return nil
    }
    guard scalars[bodyOpen] == "{", let bodyClose = matchingBrace(scalars, opening: bodyOpen) else {
        return nil
    }
    let inner = String(scalars[(bodyOpen + 1)..<bodyClose])
    return (
        ComputedMember(name: name, hasSetter: propertyBodyHasSetter(inner)),
        bodyClose + 1
    )
}

private func skipTypeAnnotationToBodyOrAssignment(_ scalars: [Character], from start: Int) -> Int? {
    var index = start
    var paren = 0
    var bracket = 0
    var angle = 0
    while index < scalars.count {
        if let next = skipTrivia(scalars, from: index), next != index {
            index = next
            continue
        }
        let char = scalars[index]
        if char == "(", paren >= 0 {
            paren += 1
        } else if char == ")" {
            paren -= 1
        } else if char == "[" {
            bracket += 1
        } else if char == "]" {
            bracket -= 1
        } else if char == "<" {
            angle += 1
        } else if char == ">" {
            angle -= 1
        } else if char == "=" && paren == 0 && bracket == 0 && angle == 0 {
            return index
        } else if char == "{" && paren == 0 && bracket == 0 && angle == 0 {
            return index
        }
        index += 1
    }
    return nil
}

private func propertyBodyHasSetter(_ body: String) -> Bool {
    let scalars = Array(body)
    var index = 0
    var depth = 0
    while index < scalars.count {
        if let next = skipTrivia(scalars, from: index) {
            index = next
        }
        guard index < scalars.count else { break }
        if scalars[index] == "{" {
            depth += 1
            index += 1
            continue
        }
        if scalars[index] == "}" {
            depth -= 1
            index += 1
            continue
        }
        if depth == 0, let word = identifier(at: index, in: scalars), String(scalars[word]) == "set" {
            return true
        }
        if let word = identifier(at: index, in: scalars) {
            index = word.upperBound
        } else {
            index += 1
        }
    }
    return false
}

private func skipToOpeningBrace(_ scalars: [Character], from start: Int) -> Int? {
    var index = start
    var paren = 0
    while index < scalars.count {
        guard let next = skipTrivia(scalars, from: index) else { return nil }
        index = next
        if scalars[index] == "(" {
            paren += 1
            index += 1
            continue
        }
        if scalars[index] == ")" {
            paren -= 1
            index += 1
            continue
        }
        if scalars[index] == "{" && paren == 0 {
            return index
        }
        index += 1
    }
    return nil
}

private func skipSignatureToBodyEnd(_ scalars: [Character], from start: Int) -> Int? {
    var index = start
    while index < scalars.count {
        if let next = skipTrivia(scalars, from: index) {
            index = next
        }
        guard index < scalars.count else { return nil }
        if scalars[index] == "{" {
            return matchingBrace(scalars, opening: index).map { $0 + 1 }
        }
        if scalars[index] == "{" || scalars[index] == "}" {
            return index
        }
        index += 1
    }
    return nil
}

private func matchingBrace(_ scalars: [Character], opening: Int) -> Int? {
    var depth = 0
    var index = opening
    while index < scalars.count {
        if let next = skipTriviaKeepingBraces(scalars, from: index) {
            if next != index {
                index = next
                continue
            }
        }
        let char = scalars[index]
        if char == "{" {
            depth += 1
        } else if char == "}" {
            depth -= 1
            if depth == 0 { return index }
        }
        index += 1
    }
    return nil
}

private func identifier(at index: Int, in scalars: [Character]) -> Range<Int>? {
    guard index < scalars.count else { return nil }
    let first = scalars[index]
    guard first.isLetter || first == "_" else { return nil }
    var end = index + 1
    while end < scalars.count {
        let char = scalars[end]
        if char.isLetter || char.isNumber || char == "_" {
            end += 1
        } else {
            break
        }
    }
    return index..<end
}

private func skipTrivia(_ scalars: [Character], from start: Int) -> Int? {
    skipTriviaKeepingBraces(scalars, from: start)
}

private func skipTriviaKeepingBraces(_ scalars: [Character], from start: Int) -> Int? {
    var index = start
    while index < scalars.count {
        let char = scalars[index]
        if char.isWhitespace {
            index += 1
            continue
        }
        if char == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
            index += 2
            while index < scalars.count, scalars[index] != "\n" {
                index += 1
            }
            continue
        }
        if char == "/", index + 1 < scalars.count, scalars[index + 1] == "*" {
            index += 2
            while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") {
                index += 1
            }
            index = min(index + 2, scalars.count)
            continue
        }
        if char == "\"" {
            index = skipString(scalars, from: index)
            continue
        }
        return index
    }
    return nil
}

private func skipString(_ scalars: [Character], from start: Int) -> Int {
    var index = start + 1
    while index < scalars.count {
        let char = scalars[index]
        if char == "\\" {
            index += 2
            continue
        }
        if char == "\"" {
            return index + 1
        }
        index += 1
    }
    return scalars.count
}
