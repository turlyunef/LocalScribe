import Foundation

/// The single owner of text-archive transactions. Synchronous transactions on
/// this actor never suspend between reading and publishing, never run on
/// MainActor, and publish snapshots with a monotonically increasing revision:
/// a creation, batch move or publication becomes visible only after its
/// catalog or document commit has succeeded.
///
/// Snapshots carry lightweight summaries plus the in-memory duplicate index;
/// full card documents are read on demand. Recovery distinguishes unfinished
/// imports (journal + no catalog entry → document removed), confirmed
/// deletions (journal + absent folder → catalog finalized) and damaged or
/// unexpectedly missing documents (reported as errors, never hidden).
public actor AnonymizationCoordinator {
    public struct Snapshot: Sendable {
        public let revision: UInt64
        /// Summaries ordered by import position; never full documents.
        public let cards: [AnonymizationCardSummary]
        public let catalog: AnonymizationArchiveCatalog
        public let catalogError: String?
        public let unreadableCardIDs: [String]
    }

    /// Draft of one import candidate as delivered by the import pipeline: the
    /// pinned original bytes (including the BOM), the decoded first source
    /// version and the import name without extension.
    public struct ImportDraft: Sendable {
        public var bytes: Data
        public var importedNameStem: String
        public var sourceFormat: AnonymizationSourceFormat
        public var source: TextRevision
        public var displayName: String?
        public init(bytes: Data, importedNameStem: String, sourceFormat: AnonymizationSourceFormat,
                    source: TextRevision, displayName: String? = nil) {
            self.bytes = bytes; self.importedNameStem = importedNameStem
            self.sourceFormat = sourceFormat; self.source = source; self.displayName = displayName
        }
    }

    private enum PendingDeletion: Sendable {
        case cards(Set<String>)
        case group(groupID: String, members: Set<String>)
    }
    private struct ScanResult: Sendable {
        var documents: [AnonymizationCardDocument]
        var unreadableIDs: [String]
    }

    private let repository: AnonymizationRepository
    private let removeCard: @Sendable (AnonymizationRepository, String) throws -> Void
    private var summaries: [AnonymizationCardSummary] = []
    private var positions: [String: Int] = [:]
    /// Duplicate index: byte length -> (SHA-256, card id, import position).
    /// The SHA is only a hint; equality is decided by the archived bytes.
    private var identities: [UInt: [(sha256: String, cardID: String, importOrder: UInt)]] = [:]
    private var initialized = false
    private var catalogInitialized = false
    private var catalog = AnonymizationArchiveCatalog()
    private var catalogError: String?
    private var unreadableCardIDs: [String] = []
    private var deletion: PendingDeletion?
    private var revision: UInt64 = 0

    public init(repository: AnonymizationRepository,
                removeCard: @escaping @Sendable (AnonymizationRepository, String) throws -> Void = { try $0.deleteCard($1) }) {
        self.repository = repository
        self.removeCard = removeCard
    }

    // MARK: - Snapshots and recovery

    public func snapshot() -> Snapshot {
        initialize()
        return Snapshot(revision: revision, cards: summaries, catalog: catalog,
                        catalogError: catalogError, unreadableCardIDs: unreadableCardIDs)
    }

    /// One pass over the archive: resolve restorable journals against the
    /// catalog, then read the cards. Interrupts `QUEUED`/`RUNNING` attempts and
    /// reports damaged, unreadable or unexpectedly missing cards without
    /// hiding or deleting them.
    public func recover() throws -> Snapshot {
        initializeCatalog()
        if catalogError == nil {
            do {
                try resolveDeletionIntention()
                try resolveImportIntentions()
            } catch {
                rebuild(scanCards())
                throw error
            }
        }
        let scan = scanCards()
        var documents: [AnonymizationCardDocument] = []
        var unreadable = scan.unreadableIDs
        for var document in scan.documents {
            if document.latestAttempt.state == .queued || document.latestAttempt.state == .running {
                document.latestAttempt.state = .interrupted
                do { try repository.saveCard(document) }
                catch { unreadable.append(document.id); continue }
            }
            documents.append(document)
        }
        rebuild(ScanResult(documents: documents, unreadableIDs: unreadable.sorted()))
        return snapshot()
    }

    // MARK: - Cards

    public func loadCard(_ id: String) throws -> AnonymizationCardDocument {
        initialize()
        return try repository.loadCard(id)
    }

    /// Read-modify-write of one card document: text revisions, attempt
    /// transitions and result publication all commit as a single atomic
    /// document write. Identity fields cannot be changed.
    @discardableResult public func updateCard(_ id: String,
                                              _ change: @Sendable (inout AnonymizationCardDocument) throws -> Void) throws -> AnonymizationCardDocument {
        initialize()
        var card = try repository.loadCard(id)
        let original = card
        try change(&card)
        guard card.id == id, card.importOrder == original.importOrder,
              card.importedNameStem == original.importedNameStem,
              card.sourceFormat == original.sourceFormat,
              card.importContentIdentity == original.importContentIdentity else {
            throw ScribeError.message("Нельзя изменить идентичность карточки обезличивания")
        }
        try repository.saveCard(card)
        publish(card)
        return card
    }

    public func rename(_ id: String, to name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ScribeError.message("Название карточки не может быть пустым") }
        _ = try updateCard(id) { $0.displayName = name }
    }

    /// Text edit of the left panel: the pure pair transformation and the new
    /// source revision commit as one atomic document write. Warnings and the
    /// substitution history stay untouched; an edit never starts an attempt.
    @discardableResult public func editSource(_ id: String, _ edit: ScalarEdit) throws -> AnonymizationCardDocument {
        try updateCard(id) { card in
            card = try AnonymizationEditing.editSource(card, edit)
        }
    }

    /// Text edit of the right (published result) panel: a new right revision
    /// with transformed pairs and warning review positions commits as one
    /// atomic document write. Requires a published result.
    @discardableResult public func editResult(_ id: String, _ edit: ScalarEdit) throws -> AnonymizationCardDocument {
        try updateCard(id) { card in
            card = try AnonymizationEditing.editResult(card, edit)
        }
    }

    /// Commit a pasted or imported text and its reverse transformation in the
    /// same card. The two revisions checked here identify the visible map.
    @discardableResult public func restoreText(_ id: String, text: String, sourceFormat: AnonymizationSourceFormat,
                                               expectedResultID: String,
                                               expectedSourceID: String) throws -> AnonymizationCardDocument {
        try ensureCardsAreNotBeingDeleted([id])
        return try updateCard(id) { card in
            try Task.checkCancellation()
            guard let result = card.publishedResult else {
                throw ScribeError.message("Результат ещё не опубликован")
            }
            guard result.text.id == expectedResultID, card.source.id == expectedSourceID else {
                throw ScribeError.message("Исходник или обезличенный текст изменился. Запустите обратное преобразование снова.")
            }
            let source = TextRevision(id: UUID().uuidString, text: text)
            card.restoration = try AnonymizationRestoration.transform(
                source, sourceFormat: sourceFormat, original: card.source.text, anonymized: result)
            try Task.checkCancellation()
        }
    }

    /// Reapply the current card's replacement pairs to the saved input.
    @discardableResult public func repeatRestoration(_ id: String,
                                                      expectedRestorationID: String) throws -> AnonymizationCardDocument {
        try ensureCardsAreNotBeingDeleted([id])
        return try updateCard(id) { card in
            try Task.checkCancellation()
            guard let published = card.publishedResult, let previous = card.restoration,
                  previous.result.id == expectedRestorationID else {
                throw ScribeError.message("Текст для обратного преобразования изменился. Повторите действие.")
            }
            card.restoration = try AnonymizationRestoration.transform(
                previous.source, sourceFormat: previous.sourceFormat, original: card.source.text, anonymized: published)
            try Task.checkCancellation()
        }
    }

    /// Import transaction: intention journal → card document → catalog commit
    /// (membership + consumed import position) → journal removal. The document
    /// becomes visible only through the catalog commit; a vanished or deleted
    /// destination group resolves to «Без темы», never to a new default.
    @discardableResult public func importCard(_ draft: ImportDraft,
                                              groupID: String = AnonymizationGroup.systemID) throws -> AnonymizationCardSummary {
        try Task.checkCancellation()
        try requireCatalog()
        try AnonymizationCardDocument.validateFileStem(draft.importedNameStem)
        guard !draft.bytes.isEmpty else { throw ScribeError.message("Файл пуст") }
        guard UUID(uuidString: draft.source.id) != nil,
              draft.source.text.contains(where: { !$0.isWhitespace }) else {
            throw ScribeError.message("Исходный текст обезличивания пуст")
        }
        let displayName = draft.displayName.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            ?? draft.importedNameStem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else { throw ScribeError.message("Название карточки не может быть пустым") }
        let cardID = UUID().uuidString
        let card = AnonymizationCardDocument(
            id: cardID,
            importOrder: catalog.nextImportPosition,
            importContentIdentity: ByteContentIdentity(bytes: draft.bytes),
            importedNameStem: draft.importedNameStem,
            sourceFormat: draft.sourceFormat,
            displayName: displayName,
            source: draft.source,
            latestAttempt: AnonymizationAttempt(state: .waitingModel))
        var committed = false
        try repository.writeImportIntention(.init(cardID: cardID, targetGroupID: groupID))
        do {
            try repository.saveCard(card)
            var next = catalog
            try next.assign(cardID, to: resolvedImportTarget(groupID))
            next.consumeImportPosition()
            try commitCatalog(next)
            committed = true
        } catch {
            // The card was never referenced by the catalog: remove the partial
            // document and the journal so nothing stays behind.
            if !committed { try? repository.deleteCard(cardID) }
            try? repository.removeImportIntention(cardID)
            throw error
        }
        // A journal-removal failure cannot uncommit the import: recovery
        // recognizes the catalog reference and cleans the journal later.
        try? repository.removeImportIntention(cardID)
        publish(card)
        return AnonymizationCardSummary(document: card)
    }

    /// Byte-exact duplicate lookup among surviving cards: candidates are
    /// narrowed by length and SHA-256, confirmed against the archived bytes
    /// (BOM included) and resolved to the latest import position.
    public func findDuplicate(of bytes: Data) -> String? {
        initialize()
        guard !bytes.isEmpty else { return nil }
        let sha = ByteContentIdentity.sha256Hex(bytes)
        let candidates = (identities[UInt(bytes.count)] ?? [])
            .filter { $0.sha256 == sha }
            .sorted { $0.importOrder > $1.importOrder }
        for candidate in candidates {
            guard let card = try? repository.loadCard(candidate.cardID),
                  card.importContentIdentity.bytes == bytes else { continue }
            return card.id
        }
        return nil
    }

    // MARK: - Groups

    public func editGroups(_ change: @Sendable (inout AnonymizationArchiveCatalog) throws -> Void) throws {
        try requireCatalog()
        guard groupDeletionID == nil else { throw ScribeError.message("Дождитесь удаления группы") }
        var next = catalog
        try change(&next)
        // An unchanged catalog (including a no-op setAllExpanded) is not written.
        if next != catalog { try commitCatalog(next) }
    }

    /// Validate the entire batch before one atomic catalog publication.
    public func moveCards(_ ids: Set<String>, to groupID: String) throws {
        try requireCatalog()
        try ensureMovable(ids, to: groupID)
        var next = catalog
        for id in ids.sorted() {
            guard positions[id] != nil else { throw ScribeError.message("Карточка больше не существует") }
            try next.assign(id, to: groupID)
        }
        if next != catalog { try commitCatalog(next) }
    }

    // MARK: - Deletion

    /// Freeze the confirmed card set and persist the deletion intention. The
    /// admission layer must close these cards and wait for their workers
    /// before `finishCardDeletion()`.
    @discardableResult public func prepareCardDeletion(_ ids: Set<String>) throws -> Set<String> {
        try requireCatalog()
        guard deletion == nil else { throw ScribeError.message("Дождитесь завершения удаления") }
        let confirmed = ids.filter { positions[$0] != nil }
        guard !confirmed.isEmpty, confirmed.count == ids.count else {
            throw ScribeError.message("Карточка больше не существует")
        }
        try repository.writeDeletionIntention(.init(confirmedCardIDs: confirmed))
        deletion = .cards(confirmed)
        return confirmed
    }

    /// Freeze the full membership of a user group and persist the deletion
    /// intention for its files, including cards hidden by search.
    @discardableResult public func prepareGroupDeletion(_ groupID: String) throws -> Set<String> {
        try requireCatalog()
        guard deletion == nil,
              catalog.groups.contains(where: { $0.id == groupID && !$0.isSystem }) else {
            throw ScribeError.message("Нельзя удалить эту группу сейчас")
        }
        let members = Set(catalog.membership.compactMap { $0.value == groupID ? $0.key : nil })
        try repository.writeDeletionIntention(.init(confirmedCardIDs: members))
        deletion = .group(groupID: groupID, members: members)
        return members
    }

    public func cancelDeletion() {
        guard deletion != nil else { return }
        deletion = nil
        try? repository.removeDeletionIntention()
    }

    /// Remove the confirmed card folders, then fix the catalog to the actual
    /// remainder and only then drop the intention journal. A folder already
    /// absent counts as removed — the confirmation is what distinguishes it
    /// from an unexpectedly missing document. A partial failure publishes the
    /// surviving archive and throws.
    public func finishCardDeletion() throws {
        guard case .cards(let confirmed) = deletion else {
            throw ScribeError.message("Удаление карточек не подготовлено")
        }
        deletion = nil
        let removed = try deleteConfirmed(confirmed)
        if removed != confirmed {
            throw ScribeError.message("Не удалось удалить часть карточек. Архив показывает фактический остаток.")
        }
    }

    /// `deleteFiles: false` moves the whole membership to «Без темы» and
    /// removes the group in one catalog write. With files, member folders are
    /// removed first; on any failure the group survives for the remainder.
    public func finishGroupDeletion(_ groupID: String, deleteFiles: Bool) throws {
        guard case .group(let preparedID, let members) = deletion, preparedID == groupID else {
            throw ScribeError.message("Удаление группы не подготовлено")
        }
        deletion = nil
        if deleteFiles {
            var removed = Set<String>()
            for id in members.sorted() {
                if repository.cardFolderStatus(id) == .absent { removed.insert(id); continue }
                do { try removeCard(repository, id); removed.insert(id) } catch { continue }
            }
            do {
                var next = catalog
                for id in removed { next.unassign(id) }
                if removed == members { try next.remove(groupID) }
                if next != catalog { try commitCatalog(next) }
                try repository.removeDeletionIntention()
            } catch {
                rebuild(scanCards())
                throw error
            }
            if !removed.isEmpty { dropCards(removed) }
            if removed != members {
                throw ScribeError.message("Не удалось удалить часть карточек. Группа сохранена для остатка.")
            }
        } else {
            var next = catalog
            for id in members { try next.assign(id, to: AnonymizationGroup.systemID) }
            try next.remove(groupID)
            try commitCatalog(next)
            try repository.removeDeletionIntention()
        }
    }

    /// File-only work shares the same serial executor as card transactions.
    public func perform<T: Sendable>(_ operation: @Sendable (AnonymizationRepository) throws -> T) rethrows -> T {
        try operation(repository)
    }

    // MARK: - Private

    private var groupDeletionID: String? {
        if case .group(let groupID, _) = deletion { return groupID }
        return nil
    }

    private func ensureMovable(_ ids: Set<String>, to groupID: String) throws {
        if groupDeletionID == groupID { throw ScribeError.message("Дождитесь удаления группы") }
        try ensureCardsAreNotBeingDeleted(ids)
    }

    private func ensureCardsAreNotBeingDeleted(_ ids: Set<String>) throws {
        if case .cards(let confirmed) = deletion, !confirmed.isDisjoint(with: ids) {
            throw ScribeError.message("Дождитесь удаления карточек")
        }
        if case .group(_, let members) = deletion, !members.isDisjoint(with: ids) {
            throw ScribeError.message("Дождитесь удаления группы")
        }
    }

    private func initialize() {
        initializeCatalog()
        if !initialized { rebuild(scanCards()) }
    }
    private func initializeCatalog() {
        guard !catalogInitialized else { return }
        do { catalog = try repository.loadCatalog() }
        catch { catalogError = "Не удалось прочитать каталог текстового архива: \(error.localizedDescription)" }
        catalogInitialized = true
    }
    private func requireCatalog() throws {
        initialize()
        if let catalogError { throw ScribeError.message(catalogError) }
    }
    private func commitCatalog(_ next: AnonymizationArchiveCatalog) throws {
        try repository.saveCatalog(next)
        catalog = next
        revision &+= 1
    }

    /// Reads all card documents and accounts for referenced-but-unreadable
    /// cards. Documents not referenced by a healthy catalog are orphans and
    /// are ignored, exactly like unrelated folders.
    private func scanCards() -> ScanResult {
        var invalid: Set<String> = []
        let documents = repository.listCards(reportInvalid: { invalid.insert($0) })
        if catalogError == nil {
            let known = Set(documents.map(\.id))
            // Every catalog reference must resolve: a missing or undecodable
            // document is an archive error, never a silent prune.
            for cardID in catalog.membership.keys where !known.contains(cardID) {
                invalid.insert(cardID)
            }
            // A position may be used by exactly one surviving document.
            var seen = Set<UInt>()
            for document in documents where catalog.membership[document.id] != nil {
                if !seen.insert(document.importOrder).inserted { invalid.insert(document.id) }
            }
        }
        let valid = documents.filter { catalogError != nil || catalog.membership[$0.id] != nil && !invalid.contains($0.id) }
        return ScanResult(documents: valid, unreadableIDs: invalid.sorted())
    }

    private func rebuild(_ result: ScanResult) {
        let documents = result.documents
        summaries = documents.map(AnonymizationCardSummary.init)
            .sorted { $0.importOrder == $1.importOrder ? $0.id < $1.id : $0.importOrder < $1.importOrder }
        positions = Dictionary(uniqueKeysWithValues: summaries.enumerated().map { ($0.element.id, $0.offset) })
        identities.removeAll()
        for document in documents { insertIdentity(document) }
        unreadableCardIDs = result.unreadableIDs
        initialized = true
        revision &+= 1
    }
    /// Drops summaries and duplicate-index entries of removed cards; the
    /// catalog itself was committed by the caller.
    private func dropCards(_ removed: Set<String>) {
        unreadableCardIDs.removeAll { removed.contains($0) }
        summaries.removeAll { removed.contains($0.id) }
        positions = Dictionary(uniqueKeysWithValues: summaries.enumerated().map { ($0.element.id, $0.offset) })
        for (length, entries) in identities {
            let filtered = entries.filter { !removed.contains($0.cardID) }
            if filtered.count != entries.count { identities[length] = filtered }
        }
        revision &+= 1
    }
    private func publish(_ card: AnonymizationCardDocument) {
        unreadableCardIDs.removeAll { $0 == card.id }
        insertIdentity(card)
        let summary = AnonymizationCardSummary(document: card)
        if let position = positions[card.id] {
            summaries[position] = summary
            revision &+= 1
        } else {
            summaries.append(summary)
            summaries.sort { $0.importOrder == $1.importOrder ? $0.id < $1.id : $0.importOrder < $1.importOrder }
            positions = Dictionary(uniqueKeysWithValues: summaries.enumerated().map { ($0.element.id, $0.offset) })
            revision &+= 1
        }
    }
    private func insertIdentity(_ card: AnonymizationCardDocument) {
        let length = card.importContentIdentity.byteLength
        var entries = identities[length] ?? []
        entries.removeAll { $0.cardID == card.id }
        entries.append((card.importContentIdentity.sha256, card.id, card.importOrder))
        identities[length] = entries
    }

    /// A destination removed or being deleted while the import pipeline was
    /// running resolves to the system group, never to a new default.
    private func resolvedImportTarget(_ requested: String) -> String {
        let unavailable = groupDeletionID == requested || !catalog.groups.contains { $0.id == requested }
        return unavailable ? AnonymizationGroup.systemID : requested
    }

    /// Deletes the confirmed folders one by one — a folder already absent
    /// counts as removed — then commits the actual remainder in the catalog
    /// and removes the journal only after that commit.
    private func deleteConfirmed(_ confirmed: Set<String>) throws -> Set<String> {
        var removed = Set<String>()
        for id in confirmed.sorted() {
            if repository.cardFolderStatus(id) == .absent { removed.insert(id); continue }
            do { try removeCard(repository, id); removed.insert(id) } catch { continue }
        }
        do {
            var next = catalog
            for id in removed { next.unassign(id) }
            if next != catalog { try commitCatalog(next) }
            try repository.removeDeletionIntention()
        } catch {
            rebuild(scanCards())
            throw error
        }
        if !removed.isEmpty { dropCards(removed) }
        return removed
    }

    /// A confirmed deletion whose folder is already absent is finalized in the
    /// catalog; a surviving folder keeps its card visible. The journal is then
    /// consumed.
    private func resolveDeletionIntention() throws {
        guard let intention = repository.loadDeletionIntention() else { return }
        var next = catalog
        for id in intention.confirmedCardIDs
        where repository.cardFolderStatus(id) == .absent && next.membership[id] != nil {
            next.unassign(id)
        }
        if next != catalog { try commitCatalog(next) }
        try repository.removeDeletionIntention()
    }
    /// An import journal whose card never entered the catalog marks an
    /// unfinished import: its document is removed. A committed import only
    /// drops the journal.
    private func resolveImportIntentions() throws {
        for intention in repository.pendingImportIntentions() {
            if catalog.membership[intention.cardID] == nil {
                try? repository.deleteCard(intention.cardID)
            }
            try repository.removeImportIntention(intention.cardID)
        }
    }
}
