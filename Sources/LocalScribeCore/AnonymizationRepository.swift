import Foundation

/// File storage of the text-anonymization archive — a sibling branch next to
/// the recordings and diagram archives with its own root, catalog and card
/// documents. Transactions, snapshots and revisions belong to
/// AnonymizationCoordinator; this structure only reads and writes files and
/// stays Sendable without actors.
///
/// Layout on disk:
/// - `catalog.json` — versioned archive catalog (groups, membership, order,
///   default group, next import position);
/// - `items/<UUID>/card.json` — one versioned document per card; the card's
///   `runs/<attempt UUID>/` folder holds worker artifacts of its attempts;
/// - `pending/import-<UUID>.json` — restorable import intention written before
///   the card document and removed after the catalog commit;
/// - `pending/deletion.json` — restorable deletion intention with the
///   confirmed card UUIDs, written before any card folder is removed.
public struct AnonymizationRepository: Sendable {
    public let root: URL
    public var catalogURL: URL { root.appendingPathComponent("catalog.json") }
    public var itemsURL: URL { root.appendingPathComponent("items") }
    public var pendingURL: URL { root.appendingPathComponent("pending") }

    public init(root: URL) throws {
        self.root = root
        try Disk.directory(itemsURL)
        try Disk.directory(pendingURL)
        try initializeCatalog()
    }

    public func folder(_ id: String) -> URL { itemsURL.appendingPathComponent(id) }
    public func cardURL(_ id: String) -> URL { folder(id).appendingPathComponent("card.json") }
    /// Worker artifacts of one attempt live under the card folder and are
    /// removed together with it.
    public func run(_ id: String, _ attemptID: String) -> URL {
        folder(id).appendingPathComponent("runs").appendingPathComponent(attemptID)
    }
    public func importIntentionURL(_ cardID: String) -> URL {
        pendingURL.appendingPathComponent("import-\(cardID).json")
    }
    public var deletionIntentionURL: URL { pendingURL.appendingPathComponent("deletion.json") }

    /// First open creates an empty archive with the system group. An existing
    /// file is never touched here — a damaged catalog must stay on disk and be
    /// reported by `loadCatalog()`, not replaced with an empty one.
    private func initializeCatalog() throws {
        guard !FileManager.default.fileExists(atPath: catalogURL.path) else { return }
        try Disk.write(AnonymizationArchiveCatalog(), to: catalogURL)
    }

    // MARK: - Catalog

    /// Only a missing file yields a fresh catalog: decoding, validation and
    /// permission errors must not reset stored organization.
    public func loadCatalog() throws -> AnonymizationArchiveCatalog {
        do {
            let catalog = try Disk.read(AnonymizationArchiveCatalog.self, at: catalogURL)
            try catalog.validate()
            return catalog
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return AnonymizationArchiveCatalog()
        }
    }
    public func saveCatalog(_ catalog: AnonymizationArchiveCatalog) throws {
        try catalog.validate()
        try Disk.write(catalog, to: catalogURL)
    }

    // MARK: - Cards

    public func loadCard(_ id: String) throws -> AnonymizationCardDocument {
        guard UUID(uuidString: id) != nil else { throw ScribeError.message("Недопустимый идентификатор карточки обезличивания") }
        let card = try Disk.read(AnonymizationCardDocument.self, at: cardURL(id))
        guard card.id == id else { throw ScribeError.message("Идентификатор карточки не совпадает с её каталогом") }
        try card.validate()
        return card
    }
    public func saveCard(_ card: AnonymizationCardDocument) throws {
        try card.validate()
        try Disk.write(card, to: cardURL(card.id), requireReadableSize: true)
    }
    /// Removes the card document and all working files of its attempts. The
    /// working files go first and the document last: when a removal fails
    /// midway (a locked run folder), the surviving card of a partially failed
    /// confirmed deletion keeps its document and stays readable in the actual
    /// remainder instead of turning into an unexpectedly missing document.
    public func deleteCard(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw ScribeError.message("Недопустимый идентификатор карточки обезличивания") }
        let cardFolder = folder(id)
        let documentName = cardURL(id).lastPathComponent
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: cardFolder.path)) ?? []
        for entry in entries where entry != documentName {
            try FileManager.default.removeItem(at: cardFolder.appendingPathComponent(entry))
        }
        try FileManager.default.removeItem(at: cardFolder)
    }

    /// Only UUID directories without symlinks that contain a document are
    /// cards. Unrelated folders are ignored; a recognizable damaged card is
    /// reported, never hidden and never deleted.
    public func listCards(reportInvalid: (String) -> Void = { _ in }) -> [AnonymizationCardDocument] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: itemsURL, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])) ?? []
        return dirs.compactMap { url -> AnonymizationCardDocument? in
            let id = url.lastPathComponent
            guard UUID(uuidString: id) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  FileManager.default.fileExists(atPath: url.appendingPathComponent("card.json").path) else { return nil }
            do { return try loadCard(id) }
            catch { reportInvalid(id); return nil }
        }.sorted { $0.importOrder == $1.importOrder ? $0.id < $1.id : $0.importOrder < $1.importOrder }
    }

    public enum CardFolderStatus: Sendable, Equatable { case present, absent, unknown }
    /// Distinguishes a confirmed-absent card folder (ENOENT) from an
    /// inaccessible one; only ENOENT proves absence.
    public func cardFolderStatus(_ id: String) -> CardFolderStatus {
        do {
            _ = try folder(id).resourceValues(forKeys: [.isDirectoryKey])
            return .present
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .absent
        } catch {
            return .unknown
        }
    }

    // MARK: - Import intentions

    /// Service journal of one unfinished import: the card UUID and target
    /// group are fixed before the card document is written and removed after
    /// the catalog commit. Recovery deletes the document of an intention whose
    /// card never entered the catalog.
    public struct ImportIntention: Codable, Sendable, Equatable {
        public var schemaVersion = 1
        public var cardID: String
        public var targetGroupID: String
        public init(cardID: String, targetGroupID: String) {
            self.cardID = cardID; self.targetGroupID = targetGroupID
        }
    }

    public func writeImportIntention(_ intention: ImportIntention) throws {
        try Disk.write(intention, to: importIntentionURL(intention.cardID))
    }
    public func removeImportIntention(_ cardID: String) throws {
        let url = importIntentionURL(cardID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
    /// All pending import intentions. An undecodable journal file still names
    /// its card in the file name, so the card can be cleaned up.
    public func pendingImportIntentions() -> [ImportIntention] {
        let files = (try? FileManager.default.contentsOfDirectory(at: pendingURL, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> ImportIntention? in
            let name = url.lastPathComponent
            guard name.hasPrefix("import-"), name.hasSuffix(".json") else { return nil }
            let cardID = String(name.dropFirst("import-".count).dropLast(".json".count))
            guard UUID(uuidString: cardID) != nil else { return nil }
            if let intention = try? Disk.read(ImportIntention.self, at: url), intention.cardID == cardID {
                return intention
            }
            return ImportIntention(cardID: cardID, targetGroupID: AnonymizationGroup.systemID)
        }.sorted { $0.cardID < $1.cardID }
    }

    // MARK: - Deletion intention

    /// Service journal of a confirmed deletion. Recovery uses it to tell an
    /// already removed document (folder absent, UUID confirmed) from an
    /// unexpectedly missing one (no confirmation) — the latter is an archive
    /// error, the former is finalized in the catalog.
    public struct DeletionIntention: Codable, Sendable, Equatable {
        public var schemaVersion = 1
        public var confirmedCardIDs: [String]
        public init(confirmedCardIDs: Set<String>) {
            self.confirmedCardIDs = confirmedCardIDs.sorted()
        }
    }

    public func writeDeletionIntention(_ intention: DeletionIntention) throws {
        try Disk.write(intention, to: deletionIntentionURL)
    }
    /// Nil when the file is absent. An undecodable journal is treated as
    /// absent: without the confirmed set, cards must stay visible.
    public func loadDeletionIntention() -> DeletionIntention? {
        guard FileManager.default.fileExists(atPath: deletionIntentionURL.path) else { return nil }
        guard let intention = try? Disk.read(DeletionIntention.self, at: deletionIntentionURL),
              intention.schemaVersion == 1 else { return nil }
        return intention
    }
    public func removeDeletionIntention() throws {
        guard FileManager.default.fileExists(atPath: deletionIntentionURL.path) else { return }
        try FileManager.default.removeItem(at: deletionIntentionURL)
    }
}
