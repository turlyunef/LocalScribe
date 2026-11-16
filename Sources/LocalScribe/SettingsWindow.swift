import AppKit
import Combine
import SwiftUI
import LocalScribeCore

@MainActor final class SettingsDraft: ObservableObject {
    @Published var backgroundRecognition: Bool {
        didSet { if backgroundRecognition && automaticLiveCaptions { automaticLiveCaptions = false } }
    }
    @Published var automaticLiveCaptions: Bool {
        didSet { if automaticLiveCaptions && backgroundRecognition { backgroundRecognition = false } }
    }
    @Published var automaticSummaries: Bool
    @Published var applicationLanguage: ApplicationLanguage
    @Published var applicationTheme: ApplicationTheme
    @Published var recordingSources: RecordingSourcePreferences
    @Published var modelIDs: [ModelRole: String] = [:]
    @Published var summaryModelID: String
    @Published var diagramModelID: String
    @Published var anonymizationProfileID: String
    @Published var dataTypesText: String
    @Published var recognitionDictionaryText: String
    private var savedRecordingSources: RecordingSourcePreferences
    private var recordingSourcesObserver: AnyCancellable?
    private let initialTaskSelections: [ModelTask: String]

    init(model: AppModel) {
        backgroundRecognition = model.backgroundRecognition
        automaticLiveCaptions = model.automaticLiveCaptions
        automaticSummaries = model.automaticSummaries
        applicationLanguage = model.applicationLanguage
        applicationTheme = model.applicationTheme
        recordingSources = model.recordingSources
        savedRecordingSources = model.recordingSources
        let settings = model.anonymizationSettings
        let summary = model.selectedTaskModel(.summary)?.id ?? ""
        let diagram = model.selectedTaskModel(.diagramRecognition)?.id ?? ""
        let anonymization = model.selectedTaskModel(.anonymization)?.id ?? ""
        summaryModelID = summary
        diagramModelID = diagram
        anonymizationProfileID = anonymization
        initialTaskSelections = [.summary: summary, .diagramRecognition: diagram, .anonymization: anonymization]
        dataTypesText = settings.dataTypes.joined(separator: "\n")
        recognitionDictionaryText = model.recognitionDictionary.joined(separator: "\n")
        recordingSourcesObserver = model.$recordingSources.dropFirst().sink { [weak self] sources in
            self?.refreshRecordingSources(sources)
        }
    }

    private func refreshRecordingSources(_ sources: RecordingSourcePreferences) {
        var updated = sources
        // Keep only fields the user has already edited in the settings window.
        func preserveEdit<Value: Equatable>(_ field: WritableKeyPath<RecordingSourcePreferences, Value>) {
            if recordingSources[keyPath: field] != savedRecordingSources[keyPath: field] {
                updated[keyPath: field] = recordingSources[keyPath: field]
            }
        }
        preserveEdit(\.microphoneEnabled)
        preserveEdit(\.systemAudioEnabled)
        preserveEdit(\.microphone)
        savedRecordingSources = sources
        if recordingSources != updated { recordingSources = updated }
    }

    var dataTypesLines: [String] { dataTypesText.components(separatedBy: .newlines) }
    var recognitionDictionaryLines: [String] { recognitionDictionaryText.components(separatedBy: .newlines) }
    func taskModelChanges(from model: AppModel) -> [ModelTask: String] {
        let selections: [ModelTask: String] = [
            .summary: summaryModelID, .diagramRecognition: diagramModelID, .anonymization: anonymizationProfileID
        ]
        return selections.filter { task, id in
            !id.isEmpty && id != initialTaskSelections[task] && id != model.anonymizationSettings.profileID(for: task)
        }
    }

    func changedModels(in library: ModelLibrary) -> [ModelRole: String] {
        modelIDs.filter { library.selectedByRole[$0.key.rawValue] != $0.value }
    }

    func hasChanges(from model: AppModel) -> Bool {
        backgroundRecognition != model.backgroundRecognition || automaticLiveCaptions != model.automaticLiveCaptions
            || automaticSummaries != model.automaticSummaries
            || applicationLanguage != model.applicationLanguage
            || applicationTheme != model.applicationTheme
            || recordingSources != model.recordingSources
            || !changedModels(in: model.modelLibrary).isEmpty
            || !taskModelChanges(from: model).isEmpty
            || AnonymizationSettings.sanitizeDataTypes(dataTypesLines) != model.anonymizationSettings.dataTypes
            || RecognitionDictionary.sanitized(recognitionDictionaryLines) != model.recognitionDictionary
    }
}

@MainActor final class SettingsWindow: NSObject, NSWindowDelegate {
    private weak var model: AppModel?
    private let defaults: UserDefaults
    private var draft: SettingsDraft?
    private(set) var window: NSWindow?

    init(model: AppModel, defaults: UserDefaults) {
        self.model = model
        self.defaults = defaults
    }

    func show(tab: SettingsTab? = nil) {
        guard let model else { return }
        if let tab { model.settingsTab = tab }
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return
        }

        let draft = SettingsDraft(model: model)
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false, screen: screen)
        window.title = L10n.text("Настройки")
        window.identifier = NSUserInterfaceItemIdentifier("settings")
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: VStack(spacing: 0) {
            ModelSettings(model: model, draft: draft)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Spacer()
                Button(L10n.text("Отмена")) { [weak self] in self?.window?.close() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("settings.cancel")
                Button(L10n.text("ОК")) { [weak self] in self?.saveAndClose() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("settings.ok")
            }
            .padding(12)
        }.environment(\.locale, L10n.locale))
        hosting.sizingOptions = []
        window.contentView = hosting

        let visible = (screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)).insetBy(dx: 24, dy: 24)
        let available = window.contentRect(forFrameRect: visible).size
        let minimum = NSSize(width: min(480, available.width), height: min(320, available.height))
        window.contentMinSize = minimum
        let saved = NSSizeFromString(defaults.string(forKey: "settingsWindowSize") ?? "")
        let size = NSSize(
            width: min(max(saved.width > 0 ? saved.width : 760, minimum.width), available.width),
            height: min(max(saved.height > 0 ? saved.height : 700, minimum.height), available.height)
        )
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        window.setFrame(NSRect(x: visible.midX - frame.width / 2, y: visible.midY - frame.height / 2,
                               width: frame.width, height: frame.height), display: false)
        self.draft = draft
        self.window = window
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
    }

    private func saveAndClose() {
        guard let model, let draft else { return }
        do {
            try model.applySettings(draft)
            window?.close()
        } catch { model.errorHandler.report(error) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, let draft, draft.hasChanges(from: model) else { return true }
        guard sender.attachedSheet == nil else { return false }
        let alert = NSAlert()
        alert.messageText = L10n.text("Сохранить изменения настроек?")
        alert.addButton(withTitle: L10n.text("Сохранить"))
        alert.addButton(withTitle: L10n.text("Не сохранять"))
        alert.addButton(withTitle: L10n.text("Продолжить редактирование")).keyEquivalent = "\u{1b}"
        alert.beginSheetModal(for: sender) { [weak self, weak sender] response in
            if response == .alertFirstButtonReturn { self?.saveAndClose() }
            if response == .alertSecondButtonReturn { sender?.close() }
        }
        return false
    }

    func windowDidResize(_ notification: Notification) {
        guard window?.inLiveResize != true else { return }
        saveWindowSize()
    }

    func windowDidEndLiveResize(_ notification: Notification) { saveWindowSize() }

    private func saveWindowSize() {
        guard let window, window.isVisible, !window.isMiniaturized else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        defaults.set(NSStringFromSize(size), forKey: "settingsWindowSize")
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        draft = nil
    }
}
