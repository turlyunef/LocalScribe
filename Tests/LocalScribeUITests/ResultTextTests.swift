import AppKit
import SwiftUI
import XCTest
import LocalScribeCore
@testable import LocalScribe

@MainActor
final class ResultTextTests: XCTestCase {
    private func textView(in view: NSView) -> NSTextView? {
        if let text = view as? NSTextView { return text }
        return view.subviews.lazy.compactMap { self.textView(in: $0) }.first
    }

    private func withResult(_ result: ResultTextView, check: (NSHostingView<ResultTextView>, NSTextView) throws -> Void) throws {
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: result)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderFront(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        try check(hosting, XCTUnwrap(textView(in: hosting)))
    }

    private func render(_ segments: [Segment], summary: Summary? = nil, part: ExportPart = .transcript) -> RenderedExport {
        var manifest = Manifest(sourceType: "import", title: "Встреча 😀", filename: "meeting.wav")
        manifest.createdAt = Date(timeIntervalSince1970: 0)
        return ExportService.renderResult(manifest: manifest,
                                          transcript: Transcript(fingerprint: "f", diarized: true, segments: segments),
                                          summary: summary, part: part, markdown: false)
    }

    func testRepeatedJumpToSameSegmentWorksAfterManualScrollingAndSelection() throws {
        let segments = (0..<100).map { Segment(id: "s\($0)", startMs: $0 * 1000, endMs: ($0 + 1) * 1000,
            text: "Фраза \($0)", language: "ru") }
        let rendered = render(segments)
        let first = ResultJumpRequest(segmentID: "s90")
        try withResult(ResultTextView(result: rendered, jumpRequest: first, onJump: { _ in })) { hosting, view in
            let expected = try XCTUnwrap(rendered.timestamps.first { $0.segmentID == "s90" }).range
            XCTAssertEqual(view.selectedRange(), expected)
            view.scrollRangeToVisible(NSRange(location: 0, length: 0))
            view.setSelectedRange(NSRange(location: 0, length: 0))
            let second = ResultJumpRequest(segmentID: "s90")
            XCTAssertNotEqual(first, second)
            hosting.rootView = ResultTextView(result: rendered, jumpRequest: second, onJump: { _ in })
            let deadline = Date().addingTimeInterval(1)
            while view.selectedRange() != expected && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(view.selectedRange(), expected)
            // Re-rendering the same request must preserve subsequent manual selection.
            view.setSelectedRange(NSRange(location: 0, length: 0))
            hosting.rootView = ResultTextView(result: rendered, jumpRequest: second, onJump: { _ in })
            hosting.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))
        }
    }

    func testJumpAndLinksDistinguishPhrasesStartingInSameSecond() throws {
        let segments = [
            Segment(id: "first", startMs: 76_100, endMs: 76_300, text: "Да 😀 [00:01:16]", language: "ru"),
            Segment(id: "second", startMs: 76_400, endMs: 77_000, text: "Да 😀 [00:01:16]", language: "ru")
        ]
        let rendered = render(segments)
        let text = rendered.text
        let result = ResultTextView(result: rendered, jumpRequest: ResultJumpRequest(segmentID: "second"), onJump: { _ in })
        try withResult(result) { _, view in
            let source = text as NSString
            let first = source.range(of: "[00:01:16]")
            let secondBlock = source.range(of: ExportService.renderSegment(segments[1], markdown: false), options: .backwards)
            let second = NSRange(location: secondBlock.location, length: first.length)
            XCTAssertNotEqual(first.location, second.location)
            XCTAssertEqual(view.selectedRange(), second)
            XCTAssertEqual(view.textStorage?.attribute(.link, at: first.location, effectiveRange: nil) as? String, "localscribe://segment/first")
            XCTAssertEqual(view.textStorage?.attribute(.link, at: second.location, effectiveRange: nil) as? String, "localscribe://segment/second")
            let quotedTimestamp = source.range(of: "[00:01:16]", options: .backwards)
            XCTAssertNil(view.textStorage?.attribute(.link, at: quotedTimestamp.location, effectiveRange: nil))
        }
    }

    func testSummaryEvidenceLinkInvokesJumpToPhrase() throws {
        let segments = [Segment(id: "phrase", startMs: 76_000, endMs: 77_000, text: "Фраза", language: "ru")]
        let summary = Summary(language: "ru", overview: [Finding(id: "f", text: "Вывод", evidenceSegmentIds: ["phrase"])])
        let rendered = render(segments, summary: summary, part: .summary)
        let text = rendered.text
        var jumped: String?
        let result = ResultTextView(result: rendered, jumpRequest: nil, onJump: { jumped = $0 })
        try withResult(result) { _, view in
            let range = (text as NSString).range(of: "[00:01:16]")
            let link = try XCTUnwrap(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil))
            XCTAssertTrue(view.delegate?.textView?(view, clickedOnLink: link, at: range.location) ?? false)
            XCTAssertEqual(jumped, "phrase")
        }
    }

    func testSameTextWithNewSegmentIDsRefreshesLinksAndJumpTarget() throws {
        let original = Segment(id: "old", startMs: 76_000, endMs: 77_000, text: "Фраза", language: "ru")
        var replacement = original
        replacement.id = "new"
        let rendered = render([original])
        let text = rendered.text
        let initial = ResultTextView(result: rendered, jumpRequest: nil, onJump: { _ in })
        try withResult(initial) { hosting, view in
            let replacementResult = render([replacement])
            XCTAssertEqual(replacementResult.text, text)
            hosting.rootView = ResultTextView(result: replacementResult, jumpRequest: ResultJumpRequest(segmentID: "new"), onJump: { _ in })
            hosting.layoutSubtreeIfNeeded()
            let range = (text as NSString).range(of: "[00:01:16]")
            let deadline = Date().addingTimeInterval(1)
            while view.selectedRange() != range && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            XCTAssertEqual(view.selectedRange(), range)
            XCTAssertEqual(view.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? String, "localscribe://segment/new")
        }
    }

    func testRepeatedSummaryReferencesKeepTheirOwnSegmentIDs() throws {
        let segments = [
            Segment(id: "first", startMs: 76_100, endMs: 76_300, text: "Первая", language: "ru"),
            Segment(id: "second", startMs: 76_400, endMs: 77_000, text: "Вторая", language: "ru")
        ]
        let summary = Summary(language: "ru", overview: [
            Finding(id: "one", text: "Цитата 😀 [00:01:16]", evidenceSegmentIds: ["second"]),
            Finding(id: "two", text: "Ещё вывод", evidenceSegmentIds: ["first", "second"])
        ])
        let rendered = render(segments, summary: summary, part: .summary)
        var jumps: [String] = []
        let result = ResultTextView(result: rendered, jumpRequest: nil, onJump: { jumps.append($0) })
        try withResult(result) { _, view in
            XCTAssertEqual(rendered.timestamps.map(\.segmentID), ["second", "first", "second"])
            for timestamp in rendered.timestamps {
                let link = try XCTUnwrap(view.textStorage?.attribute(.link, at: timestamp.range.location, effectiveRange: nil))
                XCTAssertTrue(view.delegate?.textView?(view, clickedOnLink: link, at: timestamp.range.location) ?? false)
            }
            XCTAssertEqual(jumps, ["second", "first", "second"])
            let quotedTimestamp = (rendered.text as NSString).range(of: "[00:01:16]")
            XCTAssertNil(view.textStorage?.attribute(.link, at: quotedTimestamp.location, effectiveRange: nil))
        }
    }
}
