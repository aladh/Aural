import Foundation

@MainActor
final class CheckRunner {
    private(set) var checksRun = 0
    private(set) var failures: [String] = []
    private var currentSuite = ""

    func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        print("◆ \(name)")
        body()
    }

    func suite(_ name: String, _ body: () async -> Void) async {
        currentSuite = name
        print("◆ \(name)")
        await body()
    }

    func check(_ label: String, _ condition: Bool) {
        checksRun += 1
        if !condition { fail(label) }
    }

    func equal<T: Equatable>(_ label: String, _ actual: T, _ expected: T) {
        checksRun += 1
        if actual != expected { fail("\(label): got \(actual), expected \(expected)") }
    }

    func notEqual<T: Equatable>(_ label: String, _ actual: T, _ unexpected: T) {
        checksRun += 1
        if actual == unexpected { fail("\(label): unexpectedly \(actual)") }
    }

    func nil_(_ label: String, _ value: (some Any)?) {
        checksRun += 1
        if value != nil { fail("\(label): expected nil, got \(value.map(String.init(describing:)) ?? "")") }
    }

    func notNil<T>(_ label: String, _ value: T?) {
        checksRun += 1
        if value == nil { fail(label) }
    }

    func throwsError(_ label: String, _ body: () throws -> Void) {
        checksRun += 1
        do {
            try body()
            fail("\(label): expected an error")
        } catch {}
    }

    func noThrow(_ label: String, _ body: () throws -> Void) {
        checksRun += 1
        do {
            try body()
        } catch {
            fail("\(label): unexpected error \(error)")
        }
    }

    private func fail(_ detail: String) {
        failures.append("[\(currentSuite)] \(detail)")
        print("  ✘ \(detail)")
    }

    var succeeded: Bool { failures.isEmpty }
}
