import Foundation

typealias TestCase = (name: String, body: () throws -> Void)

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

enum TestRunner {
    nonisolated(unsafe) static var failures: [String] = []

    static func run(_ suites: [(String, [TestCase])]) {
        var passed = 0
        var failed = 0
        for (suite, cases) in suites {
            for test in cases {
                let before = failures.count
                do {
                    try test.body()
                } catch {
                    failures.append("erro lançado: \(error)")
                }
                if failures.count == before {
                    passed += 1
                    print("  ✓ \(suite).\(test.name)")
                } else {
                    failed += 1
                    print("  ✗ \(suite).\(test.name)")
                    for message in failures[before...] { print("      \(message)") }
                }
            }
        }
        print("\n\(passed) passaram, \(failed) falharam")
        exit(failed == 0 ? 0 : 1)
    }
}

func expect(_ condition: Bool, _ message: @autoclosure () -> String = "", file: StaticString = #fileID, line: UInt = #line) {
    if !condition {
        TestRunner.failures.append("\(file):\(line) \(message())")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #fileID, line: UInt = #line) {
    if actual != expected {
        TestRunner.failures.append("\(file):\(line) esperado \(expected), obtido \(actual)")
    }
}

func expectClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.001, file: StaticString = #fileID, line: UInt = #line) {
    if abs(actual - expected) > tolerance {
        TestRunner.failures.append("\(file):\(line) esperado ≈\(expected), obtido \(actual)")
    }
}

/// Calendário fixo em São Paulo para testes determinísticos.
var testCalendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Sao_Paulo") ?? .current
    calendar.firstWeekday = 2
    return calendar
}

func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, calendar: Calendar = testCalendar) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? Date(timeIntervalSince1970: 0)
}

func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
        throw TestFailure(description: "fixture \(name) não encontrada")
    }
    return try Data(contentsOf: url)
}
