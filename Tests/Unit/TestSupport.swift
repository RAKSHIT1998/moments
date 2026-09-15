import XCTest
@testable import MOMENT

/// Fixed clock so date logic is deterministic: Sunday 13 September 2026, 10:00 local.
enum TestClock {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Kolkata")!
        return c
    }()
    static let now: Date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 13, hour: 10))!
    static var context: AnalysisContext { AnalysisContext(now: now, calendar: calendar) }
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date { calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
}

extension XCTestCase {
    /// Runs the full local pipeline on text and returns the result.
    func analyze(_ text: String, source: SourceType = .manual, context: AnalysisContext = TestClock.context, file: StaticString = #filePath, line: UInt = #line) async throws -> AnalysisResult {
        let input = CaptureInput(payload: .text(text), sourceType: source, createdAt: TestClock.now)
        return try await LocalIntelligenceProvider().analyze(input, context: context)
    }

    @MainActor
    func makeEnvironment() -> AppEnvironment {
        AppEnvironment(storage: try! StorageService(inMemory: true), settings: SettingsStore(defaults: UserDefaults(suiteName: "test-\(UUID().uuidString)")!), mediaDirectory: FileManager.default.temporaryDirectory.appending(path: "test-media-\(UUID().uuidString)"))
    }
}
