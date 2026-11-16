import SwiftUI
import AppKit
import LocalScribeCore

struct LiveCaptionControl: View {
    var captions: RecordingLiveCaptions?
    var disabled: Bool
    var start: () -> Void
    var stop: () -> Void

    var body: some View {
        if let captions {
            RunningControl(captions: captions, disabled: disabled, start: start, stop: stop)
        } else {
            Self.button(running: false, action: start).disabled(disabled)
        }
    }

    private static func button(running: Bool, action: @escaping () -> Void) -> some View {
        Button(running ? L10n.text("Остановить предрасшифровку") : L10n.text("Начать предрасшифровку"), action: action)
            .accessibilityIdentifier(running ? "recording.liveCaptions.stop" : "recording.liveCaptions.start")
    }

    private struct RunningControl: View {
        @ObservedObject var captions: RecordingLiveCaptions
        var disabled: Bool
        var start: () -> Void
        var stop: () -> Void

        var body: some View {
            LiveCaptionControl.button(running: captions.isRunning, action: captions.isRunning ? stop : start)
                .disabled(disabled && !captions.isRunning)
        }
    }
}

struct LiveCaptionView: View {
    @ObservedObject var captions: RecordingLiveCaptions

    var body: some View {
        VStack(spacing: 0) {
            if let status {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }
            LiveCaptionTextView(text: captions.text)
                .accessibilityIdentifier("result.liveCaptions")
        }
    }

    private var status: String? {
        switch captions.phase {
        case .preparing: return L10n.text("Подготавливаем языковой пакет macOS…")
        case .listening where captions.text.phrases.isEmpty && captions.text.tentative.isEmpty:
            return L10n.text("Ожидаем речь…")
        case .stopped where captions.text.phrases.isEmpty: return L10n.text("Здесь пока нет реплик.")
        case .languageUnavailable: return L10n.text("Этот язык недоступен для локальной предрасшифровки.")
        case .recognitionFailed: return L10n.text("Предрасшифровка прервалась.")
        case .saveFailed: return L10n.text("Не удалось сохранить предрасшифровку.")
        default: return nil
        }
    }
}

/// A stable document prefix keeps the reader's viewport on earlier phrases
/// while the recognizer rewrites the current phrase or appends new ones.
struct LiveCaptionTextView: NSViewRepresentable {
    var text: LiveCaptionText

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let view = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.isEditable = false
        view.isSelectable = true
        view.allowsUndo = false
        view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = NSSize(width: 20, height: 18)
        scroll.documentView = view
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, let storage = view.textStorage else { return }
        let coordinator = context.coordinator
        let tentative = text.tentative.map(\.text)
        guard text.phrases.count != coordinator.phraseCount || tentative != coordinator.tentative else { return }
        let clip = scroll.contentView
        let origin = clip.bounds.origin
        let atBottom = clip.documentRect.maxY - clip.bounds.maxY <= 2

        let finalized = Self.paragraphs(text.phrases.dropFirst(coordinator.phraseCount), color: .labelColor)
        let replacement = NSMutableAttributedString(attributedString: finalized)
        replacement.append(Self.paragraphs(tentative, color: .secondaryLabelColor))
        storage.replaceCharacters(in: NSRange(location: coordinator.finalizedLength,
                                               length: storage.length - coordinator.finalizedLength), with: replacement)
        coordinator.finalizedLength += finalized.length
        coordinator.phraseCount = text.phrases.count
        coordinator.tentative = tentative

        // Measure the updated document before restoring the viewport. TextKit 2
        // estimates offscreen heights, which can shift a manually scrolled view
        // when a new paragraph causes those estimates to be revised.
        if let container = view.textContainer, let layout = view.layoutManager {
            layout.ensureLayout(for: container)
            let textHeight = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
            view.setFrameSize(NSSize(width: clip.bounds.width,
                                     height: max(clip.bounds.height, ceil(textHeight + 2 * view.textContainerInset.height))))
        }
        let target = atBottom ? NSPoint(x: origin.x, y: clip.documentRect.maxY - clip.bounds.height) : origin
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: target, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    private static func paragraphs(_ phrases: some Sequence<String>, color: NSColor) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 9
        return NSAttributedString(string: phrases.map { $0 + "\n" }.joined(),
                                  attributes: [.font: NSFont.systemFont(ofSize: 19.6), .foregroundColor: color, .paragraphStyle: style])
    }

    final class Coordinator {
        var finalizedLength = 0
        var phraseCount = 0
        var tentative: [String] = []
    }
}
