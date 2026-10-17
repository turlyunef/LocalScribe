import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LocalScribeCore

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var recordingSheet = false
    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                ForEach(model.recordings) { recording in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(recording.displayTitle).lineLimit(2).fontWeight(.medium)
                        Text("\(timecode(recording.durationMs)) · \(recording.createdAt.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
                        Label(recording.state.title, systemImage: recording.state == .recording ? "record.circle.fill" : recording.state == .completed ? "checkmark.circle" : "waveform").font(.caption).foregroundStyle(recording.state == .recording ? .red : .secondary)
                    }.padding(.vertical, 5).tag(recording.id)
                }
            }
            .navigationTitle("LocalScribe")
            .navigationSplitViewColumnWidth(min: 220, ideal: 270)
            VStack(alignment: .leading, spacing: 6) {
                Label("Всё обрабатывается на Mac", systemImage: "lock.shield").font(.caption)
                SettingsLink { Text(model.modelsReady ? "Модели готовы" : "Установить модели") }.font(.caption)
            }.foregroundStyle(.secondary).padding()
        } detail: {
            VStack(spacing: 0) {
                if model.recordingID != nil {
                    HStack(spacing: 14) {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                        VStack(alignment: .leading) {
                            Text(model.finalizingRecording ? "Сохраняем аудио…" : "Встроенный микрофон · \(timecode(Int(model.elapsed*1000)))").monospacedDigit()
                            if let notice = model.soundNotice { Text(notice).font(.caption).foregroundStyle(.orange) }
                        }
                        ProgressView(value: model.level).frame(width: 100).accessibilityLabel("Уровень микрофона")
                        Spacer()
                        Button("Остановить") { Task { await model.stopRecording() } }.buttonStyle(.borderedProminent).disabled(model.finalizingRecording)
                    }.padding().background(.red.opacity(0.05))
                    Divider()
                }
                if let selected = model.selected {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(selected.displayTitle).font(.title2).fontWeight(.semibold)
                            Text(selected.state.title).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selected.state.processing {
                            ProgressView().controlSize(.small)
                            Button("Отменить") { Task { await model.cancelSelected() } }
                        } else if [.interrupted,.failed,.cancelled,.recorded,.waitingForModels].contains(selected.state), selected.state != .failed || selected.sourceComplete {
                            Button("Продолжить") { model.resume(selected.id) }.disabled(model.recordingID != nil || selected.state == .waitingForModels && !model.modelsReady)
                        }
                        Menu {
                            Button("Показать аудио в Finder", action: model.showAudio)
                            Button("Обработать заново") { model.repeatAnalysis(summaryOnly: false) }.disabled(model.busy || model.recordingID != nil || !selected.sourceComplete)
                            Menu("Пересоздать итоги") {
                                Button("Русский") { model.repeatAnalysis(summaryOnly: true, language: "ru") }
                                Button("English") { model.repeatAnalysis(summaryOnly: true, language: "en") }
                            }.disabled(model.transcript?.diarized != true || model.busy || model.recordingID != nil)
                            Divider()
                            Button("Удалить запись…", role: .destructive) { Task { await model.deleteSelected() } }.disabled(model.recordingID == selected.id)
                        } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 28)
                    }.padding(20)
                    if let error = selected.lastError { Text(error).font(.callout).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal,20).padding(.bottom,10) }
                    if selected.activeRunId != nil && selected.pendingRunId != nil { Text("Показан предыдущий успешный результат. Новая версия ещё обрабатывается.").font(.caption).foregroundStyle(.secondary).padding(.horizontal,20) }
                    HStack {
                        Picker("Результат", selection: $model.tab) { Text("Расшифровка").tag(ExportPart.transcript); Text("Итоги").tag(ExportPart.summary) }.pickerStyle(.segmented).frame(width: 270)
                        if model.tab == .summary, let summary = model.summary { Text(summary.language == "ru" ? "Русский" : "English").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Menu {
                            ForEach(ExportPart.allCases, id: \.self) { part in Button(part.rawValue) { model.copy(part) } }
                        } label: { Label("Копировать", systemImage: "doc.on.doc") } primaryAction: { model.copy(model.tab) }
                        Menu {
                            ForEach(ExportPart.allCases, id: \.self) { part in
                                Menu(part.rawValue) { Button("Markdown (.md)") { model.export(markdown: true, part: part) }; Button("Текст (.txt)") { model.export(markdown: false, part: part) } }
                            }
                        } label: { Label("Экспорт", systemImage: "square.and.arrow.up") }
                    }.padding(.horizontal,20).padding(.bottom,12)
                    Divider()
                    ResultTextView(text: model.rendered(model.tab), segments: model.transcript?.segments ?? [], targetID: model.tab == .transcript ? model.jumpTo : nil, onJump: { id in model.jumpTo = id; model.tab = .transcript })
                } else {
                    ContentUnavailableView {
                        Label("Разговор останется на вашем Mac", systemImage: "waveform")
                    } description: { Text("Запишите встроенный микрофон или импортируйте аудио.\nРасшифровка, участники и итоги — после сохранения звука.") } actions: {
                        Button("Новая запись") { recordingSheet = true }.buttonStyle(.borderedProminent).disabled(model.startingRecording || model.installing)
                        Button("Импортировать аудио", action: model.chooseImport)
                    }
                }
                if !model.status.isEmpty { Divider(); Text(model.status).font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(10) }
            }.background(Color(nsColor: .textBackgroundColor))
        }
        .toolbar {
            ToolbarItemGroup {
                Button { recordingSheet = true } label: { Label("Новая запись", systemImage: "mic") }.disabled(model.recordingID != nil || model.startingRecording || model.installing)
                Button(action: model.chooseImport) { Label("Импорт", systemImage: "square.and.arrow.down") }
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for provider in providers { _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in model.importURLs([url]) } } } }; return true
        }
        .sheet(isPresented: $recordingSheet) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Новая запись", systemImage: "mic.fill").font(.title2)
                Text("Встроенный микрофон MacBook")
                Text("Убедитесь, что участники знают о записи.").foregroundStyle(.secondary)
                Text("Голоса в наушниках не записываются. Запись можно сохранить и без установленных моделей.").font(.callout).foregroundStyle(.secondary)
                HStack { Spacer(); Button("Отмена") { recordingSheet = false }; Button("Начать") { recordingSheet = false; Task { await model.startRecording() } }.buttonStyle(.borderedProminent) }
            }.padding(28).frame(width: 440)
        }
        .disabled(model.shuttingDown)
        .alert("LocalScribe", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
    }
}

struct ResultTextView: NSViewRepresentable {
    var text: String; var segments: [Segment]; var targetID: String?; var onJump: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView(); let view = scroll.documentView as! NSTextView
        view.isEditable = false; view.isSelectable = true; view.allowsUndo = false
        view.textContainerInset = NSSize(width: 20, height: 20); view.font = .systemFont(ofSize: 14); view.delegate = context.coordinator
        view.isAutomaticLinkDetectionEnabled = false; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let view = scroll.documentView as! NSTextView; context.coordinator.onJump = onJump
        if context.coordinator.current != text {
            context.coordinator.current = text
            let value = NSMutableAttributedString(string: text, attributes: [.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.labelColor])
            for s in segments {
                let needle = "[\(timecode(s.startMs))]", range = (text as NSString).range(of: needle)
                if range.location != NSNotFound { value.addAttribute(.link, value: "localscribe://segment/\(s.id)", range: range) }
            }
            view.textStorage?.setAttributedString(value)
            context.coordinator.target = nil
        }
        if let targetID, context.coordinator.target != targetID, let s = segments.first(where: { $0.id == targetID }) {
            let range = (text as NSString).range(of: "[\(timecode(s.startMs))–\(timecode(s.endMs))]")
            if range.location != NSNotFound { view.scrollRangeToVisible(range); view.setSelectedRange(range); context.coordinator.target = targetID }
        }
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var current = ""; var target: String?; var onJump: ((String)->Void)?
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap { URL(string:$0) }
            if let url, url.scheme == "localscribe", url.host == "segment" { onJump?(url.lastPathComponent) }
            return true
        }
    }
}

struct ModelSettings: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Модели для автономной работы") {
                Text(model.modelsStatus)
                Text("Первоначальная загрузка — около 9,1 ГБ. Рекомендуется 25 ГБ свободного места.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Загрузить модели", action: model.installModels).disabled(model.installing || model.busy || model.recordingID != nil)
                    if model.installing { ProgressView().controlSize(.small); Button("Отменить", action: model.cancelInstall) }
                    else { Button("Проверить") { Task { await model.verifyModels() } } }
                }
                ForEach(model.catalog?.models ?? []) { profile in
                    HStack { Text(profile.id == "asr" ? "Распознавание · large-v3" : profile.id == "diarization" ? "Участники · SpeakerKit" : profile.id == "summary" ? "Итоги · Qwen3.5-9B" : "Токенизатор речи"); Spacer(); Text(ByteCountFormatter.string(fromByteCount: profile.bytes,countStyle:.file)).foregroundStyle(.secondary); Button("Из папки…") { model.importModel(profile) }.disabled(model.installing || model.busy || model.recordingID != nil) }
                }
                Button("Удалить модели…", role: .destructive, action: model.removeModels).disabled(model.busy || model.installing || model.recordingID != nil)
            }
            Section("Локальные данные") {
                Button("Показать папку данных") { if let root = model.repository?.root { NSWorkspace.shared.open(root) } }
                Button("Лицензии") { NSWorkspace.shared.open(model.resources.appendingPathComponent("Licenses")) }
                Text("LocalScribe " + (Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "0.1") + " · локальная предварительная сборка").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}
