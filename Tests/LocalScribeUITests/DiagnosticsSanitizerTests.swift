import XCTest
import LocalScribeCore
@testable import LocalScribe

/// Sanitizers and fixed retention of the diagnostics journal: identifiers pass
/// an ASCII allowlist capped at 128 UTF-8 bytes, audio extensions are mapped
/// through a closed list, the environment keeps only Apple Silicon chip names,
/// and history is trimmed to the last 80 events and 30 reports.
@MainActor final class DiagnosticsSanitizerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try super.tearDownWithError()
    }

    private func event(_ session: UUID) -> DiagnosticEvent {
        DiagnosticEvent(time: Date(), session: session, kind: .appStarted)
    }

    private func report(id: UUID) -> DiagnosticReport {
        DiagnosticReport(schemaVersion: 1, id: id, time: Date(), environment: DiagnosticEnvironment(),
                         operation: .recording, failure: DiagnosticFailure(.operationFailed),
                         job: nil, worker: nil, events: [])
    }

    // MARK: DiagnosticField

    func testIdentifierAcceptsAllowlistedCharactersUpTo128Bytes() {
        XCTAssertEqual(DiagnosticField.identifier("LocalScribe.whisper-large-v3_turbo.0119"),
                       "LocalScribe.whisper-large-v3_turbo.0119")
        let long = String(repeating: "a", count: 128)
        XCTAssertEqual(DiagnosticField.identifier(long), long)
        XCTAssertNil(DiagnosticField.identifier(String(repeating: "a", count: 129)))
        XCTAssertNil(DiagnosticField.identifier(""))
    }

    func testIdentifierRejectsEverythingOutsideTheByteAllowlist() {
        for invalid in ["with space", "slash/one", "back\\slash", "hash#1", "id\n", "id\t",
                        "café", "модель", "模型", "id;drop"] {
            XCTAssertNil(DiagnosticField.identifier(invalid), "Must reject \(invalid.debugDescription)")
        }
    }

    func testAudioFormatPassesKnownExtensionsThroughAndMapsTheRestToOther() {
        for known in ["wav", "caf", "aac", "m4a", "mp4", "mp3", "flac", "ogg", "oga", "opus", "aif", "aiff"] {
            XCTAssertEqual(DiagnosticField.audioFormat(known), known)
        }
        for unknown in ["WAV", "Txt", "wav ", " m4a", "m4b", "aif+", "", "exe"] {
            XCTAssertEqual(DiagnosticField.audioFormat(unknown), "other", "Must map \(unknown.debugDescription)")
        }
    }

    // MARK: DiagnosticEnvironment

    func testEnvironmentKeepsOnlyAppleSiliconChipNames() {
        XCTAssertNil(DiagnosticEnvironment().chip)
        XCTAssertNil(DiagnosticEnvironment().ramBytes)

        for kept in ["Apple Silicon", "Apple M1", "Apple M4", "Apple M12",
                     "Apple M1 Pro", "Apple M2 Max", "Apple M3 Ultra"] {
            let hardware = ModelHardware(chip: kept, memoryBytes: 1, cpuCores: 1, gpuWorkingSetBytes: 1,
                                         appleSilicon: true, supportsMetal: true)
            XCTAssertEqual(DiagnosticEnvironment(hardware: hardware).chip, kept)
        }
        for dropped in ["Apple M", "Apple Mx", "Apple M1 Pro Max", "Apple M1Pro", "apple m1",
                        "Intel Core i9", "", "Apple M1 Pro "] {
            let hardware = ModelHardware(chip: dropped, memoryBytes: 17_179_869_184, cpuCores: 10,
                                         gpuWorkingSetBytes: 1, appleSilicon: true, supportsMetal: true)
            let environment = DiagnosticEnvironment(hardware: hardware)
            XCTAssertNil(environment.chip, "Must drop \(dropped.debugDescription)")
            // RAM is reported regardless of the chip name.
            XCTAssertEqual(environment.ramBytes, 17_179_869_184)
        }
    }

    func testEnvironmentReportsSanitizedAppAndMacOSVersions() {
        let environment = DiagnosticEnvironment()
        XCTAssertEqual(environment.appVersion, AppInfo.version, "Dotted app version must survive the identifier filter")
        XCTAssertEqual(environment.build, AppInfo.build)
        XCTAssertNotEqual(environment.appVersion, "unknown")
        XCTAssertNotNil(environment.macOS.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression))
    }

    // MARK: DiagnosticsJournal retention

    func testJournalRetainsAtMostTheLastEightyEvents() async throws {
        let journal = DiagnosticsJournal(root: root)
        let sessions = (0..<80).map { _ in UUID() }
        for session in sessions { journal.append(event: event(session)) }
        var history = await journal.snapshot()
        XCTAssertEqual(history.events.count, 80)
        XCTAssertEqual(history.events.map(\.session), sessions, "Eighty events fit without trimming")
        XCTAssertTrue(history.reports.isEmpty)

        let extra = UUID()
        journal.append(event: event(extra))
        history = await journal.snapshot()
        XCTAssertEqual(history.events.count, 80)
        XCTAssertEqual(history.events.map(\.session), Array(sessions.dropFirst()) + [extra],
                       "The eighty-first event must drop only the oldest one")
    }

    func testJournalRetainsAtMostTheLastThirtyReports() async throws {
        let journal = DiagnosticsJournal(root: root)
        let ids = (0..<30).map { _ in UUID() }
        for id in ids {
            journal.append(event: event(UUID()), report: report(id: id))
        }
        var history = await journal.snapshot()
        XCTAssertEqual(history.reports.count, 30)
        XCTAssertEqual(history.reports.map(\.id), ids, "Thirty reports fit without trimming")
        XCTAssertEqual(history.events.count, 30, "Events below eighty are not trimmed")

        let extra = UUID()
        journal.append(event: event(UUID()), report: report(id: extra))
        history = await journal.snapshot()
        XCTAssertEqual(history.reports.count, 30)
        XCTAssertEqual(history.reports.map(\.id), Array(ids.dropFirst()) + [extra],
                       "The thirty-first report must drop only the oldest one")
    }

    func testJournalReloadsTrimmedHistoryFromDisk() async throws {
        let journal = DiagnosticsJournal(root: root)
        let sessions = (0..<95).map { _ in UUID() }
        let ids = (0..<33).map { _ in UUID() }
        for index in 0..<95 {
            if index < 33 {
                journal.append(event: event(sessions[index]), report: report(id: ids[index]))
            } else {
                journal.append(event: event(sessions[index]))
            }
        }
        let history = await journal.snapshot()  // also waits for the last Disk.write
        XCTAssertEqual(history.events.count, 80)
        XCTAssertEqual(history.reports.count, 30)

        let reopened = DiagnosticsJournal(root: root)
        let reloaded = await reopened.snapshot()
        XCTAssertEqual(reloaded.schemaVersion, 1)
        XCTAssertEqual(reloaded.events.map(\.session), Array(sessions.suffix(80)))
        XCTAssertEqual(reloaded.reports.map(\.id), Array(ids.suffix(30)))
    }

    func testJournalStartsEmptyWhenHistoryFileIsUnreadableOrOversized() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("diagnostic-history.json")
        try Data("broken".utf8).write(to: file)
        let corrupted = await DiagnosticsJournal(root: root).snapshot()
        XCTAssertTrue(corrupted.events.isEmpty)
        XCTAssertTrue(corrupted.reports.isEmpty)

        try Data(repeating: 123, count: 4 * 1024 * 1024 + 1).write(to: file)
        let oversized = await DiagnosticsJournal(root: root).snapshot()
        XCTAssertTrue(oversized.events.isEmpty)
        XCTAssertTrue(oversized.reports.isEmpty)
    }
}
