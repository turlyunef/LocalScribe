import XCTest
import SwiftUI
import AppKit
import Darwin
import Synchronization
@testable import LocalScribe
@testable import LocalScribeCore

/// Opt-in release benchmark: fixtures and archive initialization are outside query timing.
@MainActor final class RecordingSearchPerformanceTests: XCTestCase {
    private func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }
    private func report(_ name: String, _ values: [Double]) {
        let sorted = values.sorted()
        func p(_ fraction: Double) -> Double { sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)] }
        print("SEARCH BENCH \(name) n=\(values.count) p50=\(p(0.50)) p95=\(p(0.95)) p99=\(p(0.99)) max=\(sorted.last!) ms")
    }
    private func rss() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    private func corpus(_ count: Int) -> [Manifest] {
        let alphabet = Array("абвгдежзиклмнопрстуфхцчшэюя")
        return (0..<count).map { number in
            var n = number, suffix = ""
            for _ in 0..<4 { suffix.append(alphabet[n % alphabet.count]); n /= alphabet.count }
            // Shared prefixes, unique near words and RU/EN/numeric tokens. Median ~40.
            let title = number % 2 == 0 ? "Встреча планирование\(suffix) review \(number)" : "Sprint проектирование\(suffix) отчёт Q4 \(number)"
            var row = Manifest(sourceType: "import", title: title, filename: "a.wav")
            row.createdAt = Date(timeIntervalSince1970: Double(number)); return row
        }
    }
    func testReleaseResponsivenessAndStress() async throws {
        guard ProcessInfo.processInfo.environment["LOCALSCRIBE_SEARCH_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in synthetic release search benchmark")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = try RecordingRepository(root: root)
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = AppModel(repository: repo, startServices: false, userDefaults: defaults)
        await model.reload()
        let queries = ["встеча", "планирваине", "проктирование", "sprnit отч", "вст планирваине", "отчет q4", "планхрование", "проектирваоние", "review", "2026", "в", "вс", "вст", "встеч", "бюдж отпуск", "планирваине review"]
        let preparedQueries = queries.map { RecordingTitleSearch.tokens($0) }
        for count in [1000, 10000, 50000] {
            let rows = corpus(count)
            let lengths = rows.map { $0.displayTitle.count }.sorted()
            print("SEARCH BENCH corpus=\(count) graphemes median=\(lengths[count / 2]) p95=\(lengths[Int(Double(count) * 0.95)])")
            let beforeMemory = rss(), start = ContinuousClock.now
            let index = try await Task.detached { try RecordingTitleSearch.Index(titles: rows.map { .init(id: $0.id, title: $0.displayTitle) }) }.value
            print("SEARCH BENCH index=\(count) ms=\(milliseconds(start.duration(to: .now))) rssDelta=\(Int64(rss()) - Int64(beforeMemory)) bytes")
            let pure = try await Task.detached { () throws -> [Double] in
                var samples: [Double] = []
                for i in 0..<216 {
                    let start = ContinuousClock.now
                    _ = try index.matches(preparedQueries[i % preparedQueries.count])
                    if i >= 16 {
                        let d = start.duration(to: .now)
                        samples.append(Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15)
                    }
                }
                return samples
            }.value
            report("pure \(count)", pure)
            model.recordings = rows; await model.recordingSearch.waitUntilIdle()
            var steadyMemory = rss()
            var e2e: [Double] = [], mainBlocks: [Double] = []
            for i in 0..<216 {
                let start = ContinuousClock.now
                model.recordingSearch.query = queries[i % queries.count]
                let input = start.duration(to: .now)
                await model.recordingSearch.waitUntilIdle()
                if i == 15 { steadyMemory = rss() }
                if i >= 16 {
                    e2e.append(milliseconds(start.duration(to: .now)))
                    mainBlocks.append(milliseconds(input)); mainBlocks.append(milliseconds(model.recordingSearch.lastApplyDuration))
                }
            }
            report("input-publication \(count)", e2e); report("main-block \(count)", mainBlocks)
            print("SEARCH BENCH repeated=\(count) rssDelta=\(Int64(rss()) - Int64(steadyMemory)) bytes")
            var rapid: [Double] = []
            for i in 0..<20 {
                for (step, query) in ["в", "вс", "вст", "встеч", "встеча", "планирваине review", "планирваине", ""].enumerated() {
                    model.recordingSearch.query = query
                    try await Task.sleep(for: .milliseconds(30 + (i + step) % 6 * 10))
                }
                let start = ContinuousClock.now
                model.recordingSearch.query = queries[i % queries.count]
                await model.recordingSearch.waitUntilIdle()
                rapid.append(milliseconds(start.duration(to: .now)))
            }
            report("rapid-final \(count)", rapid)
            // Cancel a long-token search while the normal worker supervisor runs a CPU fixture.
            if count == 50000 {
                let command = WorkerCommand(jobId: UUID().uuidString, runId: UUID().uuidString, stage: .preparingAudio,
                    recordingPath: root.path, modelsPath: root.path, toolsPath: root.path)
                let executable = root.appendingPathComponent("search-worker.py")
                let script = """
                #!/usr/bin/python3
                import sys,json
                c=json.loads(sys.stdin.readline())
                print(json.dumps(dict(version=1,jobId=c['jobId'],runId=c['runId'],type='progress',message='ready')),flush=True)
                n=0
                while True: n=(n+1)%1000003
                """
                try script.write(to: executable, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
                var ready = false
                let worker = Task { try? await model.supervisor.run(command, executable: executable) { _ in ready = true } }
                let readyDeadline = ContinuousClock.now + .seconds(5)
                while !ready, ContinuousClock.now < readyDeadline { try await Task.sleep(for: .milliseconds(10)) }
                guard ready else {
                    worker.cancel()
                    await worker.value
                    XCTFail("Search benchmark worker did not start")
                    return
                }
                var cancellation: [Double] = [], workerSamples: [Double] = [], longInput: [Double] = []
                let longTitle = String(repeating: "п", count: 8192) + "а"
                model.recordings.append(longRowWithNewID(longTitle))
                await model.recordingSearch.waitUntilIdle()
                for i in 0..<20 {
                    let inputStart = ContinuousClock.now
                    model.recordingSearch.query = String(repeating: "п", count: 8192) + "б"
                    longInput.append(milliseconds(inputStart.duration(to: .now)))
                    try await Task.sleep(for: .milliseconds(1))
                    let start = ContinuousClock.now
                    model.recordingSearch.query = ""
                    await model.recordingSearch.waitUntilIdle()
                    cancellation.append(milliseconds(start.duration(to: .now)))
                    let next = ContinuousClock.now
                    model.recordingSearch.query = queries[i % queries.count]
                    await model.recordingSearch.waitUntilIdle()
                    workerSamples.append(milliseconds(next.duration(to: .now)))
                }
                try await nativeStress(model)
                report("long-input 50000 worker", longInput)
                report("cancel-to-idle 50000 worker", cancellation)
                report("input-publication 50000 worker", workerSamples)
                XCTAssertTrue(model.supervisor.running)
                await model.supervisor.cancel(); await worker.value
            }
        }
        await model.shutdown()
    }
    private func nativeStress(_ model: AppModel) async throws {
        let beforeWindowMemory = rss()
        _ = NSApplication.shared
        let view = NSHostingView(rootView: RecordingGroupsSidebar(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view
        window.makeKeyAndOrderFront(nil); window.makeFirstResponder(view)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100)); view.layoutSubtreeIfNeeded()
        let find = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        NSApplication.shared.sendEvent(find)
        try await Task.sleep(for: .milliseconds(100))
        let editor = try XCTUnwrap(window.firstResponder as? NSTextView)
        var gaps: [Double] = [], inputs: [Double] = []
        let ticker = Task { @MainActor in
            var previous = ContinuousClock.now
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                let now = ContinuousClock.now
                gaps.append(milliseconds(previous.duration(to: now))); previous = now
            }
        }
        for query in ["в", "вс", "вст", "встеч", "встеча", "встреча review", "встреча", "вст", "в", "", "планирваине", "review"] {
            let start = ContinuousClock.now
            editor.selectAll(nil); editor.insertText(query, replacementRange: editor.selectedRange())
            inputs.append(milliseconds(start.duration(to: .now)))
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(window.firstResponder === editor)
        }
        await model.recordingSearch.waitUntilIdle()
        XCTAssertEqual(model.recordingSearch.query, "review")
        ticker.cancel(); await ticker.value
        print("SEARCH BENCH native-window 50000 rssDelta=\(Int64(rss()) - Int64(beforeWindowMemory)) bytes")
        report("native-input 50000 worker", inputs)
        report("native-main-tick-gap 50000 worker", gaps)
    }
    private func longRowWithNewID(_ title: String) -> Manifest {
        Manifest(sourceType: "import", title: title, filename: "a.wav")
    }
}
