import AppKit
import SwiftUI
import LocalScribeCore

struct AnonymizationComparisonView<Left: View, Right: View, Actions: View>: View {
    @ObservedObject var scrollSync: AnonymizationScrollSync
    @ViewBuilder let left: (AnonymizationScrollSync) -> Left
    @ViewBuilder let right: (AnonymizationScrollSync) -> Right
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(L10n.text("Синхронизировать"), isOn: $scrollSync.isEnabled)
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("texts.detail.syncScrolling")
                Spacer()
                actions()
            }
            .controlSize(.small)
            .frame(minHeight: 24)
            HStack(alignment: .top, spacing: 16) {
                left(scrollSync)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                right(scrollSync)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

extension AnonymizationComparisonView where Actions == EmptyView {
    init(scrollSync: AnonymizationScrollSync,
         @ViewBuilder left: @escaping (AnonymizationScrollSync) -> Left,
         @ViewBuilder right: @escaping (AnonymizationScrollSync) -> Right) {
        self.init(scrollSync: scrollSync, left: left, right: right, actions: EmptyView.init)
    }
}

/// Match progress through each scrollable document, including panels with
/// different line wrapping or lengths. AppKit owns both clip bounds.
@MainActor final class AnonymizationScrollSync: NSObject, ObservableObject {
    enum Side { case left, right }

    @Published var isEnabled = true {
        didSet {
            if isEnabled && !oldValue { synchronize(from: driver) }
        }
    }

    private weak var left: NSScrollView?
    private weak var right: NSScrollView?
    private var driver: Side = .left
    private var isReflecting = false

    func connect(_ scrollView: NSScrollView, side: Side) {
        guard connection(for: side) !== scrollView else { return }
        if let previous = connection(for: side) { disconnect(previous, side: side) }
        switch side {
        case .left: left = scrollView
        case .right: right = scrollView
        }
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsDidChange(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    func disconnect(_ scrollView: NSScrollView, side: Side) {
        guard connection(for: side) === scrollView else { return }
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification,
                                                  object: scrollView.contentView)
        switch side {
        case .left: left = nil
        case .right: right = nil
        }
    }

    private func connection(for side: Side) -> NSScrollView? {
        switch side {
        case .left: left
        case .right: right
        }
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        guard !isReflecting, let clip = notification.object as? NSClipView else { return }
        if clip === left?.contentView { driver = .left }
        else if clip === right?.contentView { driver = .right }
        else { return }
        if isEnabled { synchronize(from: driver) }
    }

    private func synchronize(from side: Side) {
        guard !isReflecting, let source = connection(for: side)?.contentView,
              let target = connection(for: side == .left ? .right : .left) else { return }
        let sourceTravel = source.documentRect.height - source.bounds.height
        let targetClip = target.contentView
        let targetTravel = targetClip.documentRect.height - targetClip.bounds.height
        guard sourceTravel > 0, targetTravel > 0 else { return }
        let progress = (source.bounds.minY - source.documentRect.minY) / sourceTravel
        var targetBounds = targetClip.bounds
        targetBounds.origin.y = targetClip.documentRect.minY + min(max(progress, 0), 1) * targetTravel
        let origin = targetClip.constrainBoundsRect(targetBounds).origin
        guard targetClip.bounds.origin != origin else { return }
        isReflecting = true
        defer { isReflecting = false }
        targetClip.scroll(to: origin)
        target.reflectScrolledClipView(targetClip)
    }
}
