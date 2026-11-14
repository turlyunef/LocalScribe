import AppKit
import XCTest
@testable import LocalScribe

@MainActor
final class AnonymizationScrollSyncTests: XCTestCase {
    func testBothPanesDriveProportionalScrollingAndToggleAllowsIndependentScrolling() {
        let left = scrollView(documentHeight: 700)
        let right = scrollView(documentHeight: 1300)
        let sync = AnonymizationScrollSync()
        sync.connect(left, side: .left)
        sync.connect(right, side: .right)

        XCTAssertTrue(sync.isEnabled)
        scroll(left, to: 0.25)
        XCTAssertEqual(progress(of: right), 0.25, accuracy: 0.01)
        scroll(right, to: 0.75)
        XCTAssertEqual(progress(of: left), 0.75, accuracy: 0.01)

        sync.isEnabled = false
        scroll(right, to: 0.10)
        XCTAssertEqual(progress(of: left), 0.75, accuracy: 0.01)
        scroll(left, to: 0.45)
        XCTAssertEqual(progress(of: right), 0.10, accuracy: 0.01)
        sync.isEnabled = true
        XCTAssertEqual(progress(of: right), 0.45, accuracy: 0.01)

        sync.disconnect(left, side: .left)
        scroll(left, to: 0.9)
        XCTAssertEqual(progress(of: right), 0.45, accuracy: 0.01)
    }

    private func scrollView(documentHeight: CGFloat) -> NSScrollView {
        let scrollView = NSScrollView(frame: CGRect(x: 0, y: 0, width: 180, height: 100))
        scrollView.documentView = NSView(frame: CGRect(x: 0, y: 0, width: 180, height: documentHeight))
        return scrollView
    }

    private func scroll(_ scrollView: NSScrollView, to progress: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: clip.documentRect.minY + progress * travel(of: clip)))
    }

    private func progress(of scrollView: NSScrollView) -> CGFloat {
        let clip = scrollView.contentView
        return (clip.bounds.minY - clip.documentRect.minY) / travel(of: clip)
    }

    private func travel(of clip: NSClipView) -> CGFloat {
        clip.documentRect.height - clip.bounds.height
    }
}
