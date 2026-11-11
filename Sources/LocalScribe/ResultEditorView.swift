import SwiftUI
import LocalScribeCore

struct ResultEditorView: View {
    let initial: ResultEditDraft
    let save: (ResultEditDraft) async throws -> Void
    let cancel: () -> Void
    @State private var draft: ResultEditDraft
    @State private var part: ExportPart
    @State private var presentedPart: ExportPart? = .transcript
    @State private var saving = false
    @State private var pendingDeletion: Segment?
    let reportError: (Error) -> Void

    init(initial: ResultEditDraft, initialPart: ExportPart = .transcript,
         save: @escaping (ResultEditDraft) async throws -> Void, cancel: @escaping () -> Void,
         reportError: @escaping (Error) -> Void) {
        self.initial = initial; self.save = save; self.cancel = cancel; self.reportError = reportError
        _draft = State(initialValue: initial)
        _part = State(initialValue: initialPart == .summary ? .summary : .transcript)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("Редактирование результата")).font(.title2).fontWeight(.semibold)
            Text(L10n.text("Итоги не пересоздаются автоматически после правки реплик."))
                .font(.callout).foregroundStyle(.secondary)
            Picker(L10n.text("Раздел результата"), selection: $part) {
                Text(ExportPart.transcript.title).tag(ExportPart.transcript)
                Text(ExportPart.summary.title).tag(ExportPart.summary)
            }.pickerStyle(.segmented).labelsHidden()
            ZStack {
                if presentedPart == part {
                    editorContent
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text("Загрузка раздела результата"))
                        .accessibilityIdentifier("edit.loading")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: part) {
                let requestedPart = part
                guard presentedPart != requestedPart else { return }
                // Let the loading view appear before constructing the new editor controls.
                await Task.yield()
                guard !Task.isCancelled, part == requestedPart else { return }
                presentedPart = requestedPart
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(L10n.text("Отмена"), action: cancel).keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("edit.cancel")
                Button(L10n.text("Сохранить")) {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await save(draft) }
                        catch { reportError(error) }
                    }
                }
                .keyboardShortcut("s", modifiers: .command).buttonStyle(.borderedProminent)
                .disabled(draft.transcript == initial.transcript && draft.summary == initial.summary)
                .accessibilityIdentifier("edit.save")
            }
        }
        .padding(24).frame(minWidth: 700, idealWidth: 800, minHeight: 550, idealHeight: 700)
        .disabled(saving)
        // An explicit Cancel prevents accidental loss of a draft on Escape or click outside.
        .interactiveDismissDisabled()
        .alert(L10n.text("Удалить реплику?"), isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { segment in
            Button(L10n.text("Удалить связь и реплику"), role: .destructive) {
                draft.deleteSegment(segment.id, removingEvidence: true)
                pendingDeletion = nil
            }.accessibilityIdentifier("edit.confirmDeleteSegment")
            Button(L10n.text("Отмена"), role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text(L10n.text("Реплика используется в Итогах как обоснование. Удалить связь и реплику? Пункты итогов сохранятся."))
        }
    }

    private var editorContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if part == .transcript {
                    ForEach($draft.transcript.segments) { $segment in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(timecode(segment.startMs)) · \(speakerName(segment.speakerId))")
                                    .font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button(L10n.text("Удалить реплику"), systemImage: "trash", role: .destructive) {
                                    if !draft.deleteSegment(segment.id) { pendingDeletion = segment }
                                }
                                .labelStyle(.iconOnly).help(L10n.text("Удалить реплику"))
                                .accessibilityLabel(L10n.text("Удалить реплику %1$@", timecode(segment.startMs)))
                                .accessibilityIdentifier("edit.deleteSegment.\(segment.id)")
                            }
                            TextEditor(text: $segment.text).font(.body)
                                .frame(minHeight: 80).border(.quaternary)
                                .accessibilityLabel(L10n.text("Текст реплики %1$@", timecode(segment.startMs)))
                                .accessibilityIdentifier("edit.segment.\(segment.id)")
                        }
                    }
                } else if draft.summary != nil {
                    summarySection(L10n.text("Обзор"), keyPath: \.overview)
                    summarySection(L10n.text("Решения"), keyPath: \.decisions)
                    summarySection(L10n.text("Задачи"), keyPath: \.tasks)
                    summarySection(L10n.text("Открытые вопросы"), keyPath: \.openQuestions)
                } else {
                    Text(L10n.text("Итоги ещё не созданы.")).foregroundStyle(.secondary)
                    Button(L10n.text("Добавить итоги")) { draft.summary = Summary(language: draft.transcript.primaryLanguage) }
                }
            }.padding(4)
        }
        .contentMargins(.trailing, 20, for: .scrollContent)
        .id(part)
    }

    private func findings(_ keyPath: WritableKeyPath<Summary, [Finding]>) -> Binding<[Finding]> {
        Binding(get: { draft.summary?[keyPath: keyPath] ?? [] },
                set: { draft.summary?[keyPath: keyPath] = $0 })
    }

    private func optionalText(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: {
            value.wrappedValue = $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
        })
    }

    private func summarySection(_ title: String, keyPath: WritableKeyPath<Summary, [Finding]>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            ForEach(findings(keyPath)) { $finding in
                VStack(alignment: .leading, spacing: 8) {
                    TextField(L10n.text("Текст пункта"), text: $finding.text, axis: .vertical)
                        .lineLimit(2...10).textFieldStyle(.roundedBorder)
                        .accessibilityLabel(L10n.text("%1$@: текст пункта", title))
                        .accessibilityIdentifier("edit.finding.\(finding.id)")
                    Picker(L10n.text("Спикер ответственного"), selection: $finding.ownerSpeakerId) {
                        Text(L10n.text("Не указан")).tag(nil as String?)
                        ForEach(Array(Set(draft.transcript.segments.compactMap(\.speakerId) + [finding.ownerSpeakerId].compactMap { $0 })).sorted(), id: \.self) { id in
                            Text(speakerName(id)).tag(Optional(id))
                        }
                    }
                    HStack {
                        TextField(L10n.text("Ответственный (необязательно)"), text: optionalText($finding.ownerName))
                        TextField(L10n.text("Срок (необязательно)"), text: optionalText($finding.dueText))
                    }
                    HStack {
                        Menu(L10n.text("Основания: %1$@", String(finding.evidenceSegmentIds.count))) {
                            ForEach(draft.transcript.segments) { segment in
                                Toggle("\(timecode(segment.startMs)) · \(segment.text.prefix(70))", isOn: Binding(
                                    get: { finding.evidenceSegmentIds.contains(segment.id) },
                                    set: { included in
                                        if included {
                                            finding.evidenceSegmentIds.append(segment.id)
                                            if segment.uncertain { finding.uncertain = true }
                                        } else { finding.evidenceSegmentIds.removeAll { $0 == segment.id } }
                                    }))
                            }
                        }
                        Toggle(L10n.text("Есть неопределённость"), isOn: $finding.uncertain)
                            .disabled(draft.transcript.segments.contains { $0.uncertain && finding.evidenceSegmentIds.contains($0.id) })
                        Spacer()
                        Button(L10n.text("Удалить пункт"), systemImage: "trash", role: .destructive) {
                            draft.summary?[keyPath: keyPath].removeAll { $0.id == finding.id }
                        }.labelStyle(.iconOnly).help(L10n.text("Удалить пункт из раздела «%1$@»", title))
                    }.font(.caption)
                }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
            }
            Button(L10n.text("Добавить пункт")) {
                let first = draft.transcript.segments.first
                draft.summary?[keyPath: keyPath].append(Finding(id: UUID().uuidString, text: "",
                    evidenceSegmentIds: first.map { [$0.id] } ?? [], uncertain: first?.uncertain ?? false))
            }
        }
    }
}
