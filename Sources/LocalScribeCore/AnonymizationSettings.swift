import Foundation

/// Mode of the model assignments for summaries, diagram recognition and
/// anonymization. Speech recognition and diarization always keep their own
/// separate selections.
public enum ModelAssignmentMode: String, Codable, CaseIterable, Sendable, Hashable {
    case separate = "SEPARATE"
    case shared = "SHARED"
}

/// The saved settings record of the anonymization feature (schema version 1):
/// the assignment mode, the shared profile, the per-task separate slots and
/// the ordered data-type wordings. One atomic write stores the whole record;
/// speech and diarization selections stay in `ModelLibrary`.
///
/// The record is additive: it lives in its own file, and the previous
/// application version keeps reading its own settings unchanged. A rollback
/// never rewrites old keys, and the record survives it to be read again on
/// return.
public struct AnonymizationSettings: Codable, Equatable, Sendable {
    /// Initial data types of a fresh record (AC-27).
    public static let initialDataTypes = ["Имена и фамилии", "Телефоны", "Адреса электронной почты", "Почтовые адреса"]

    public var schemaVersion = 1
    public var modelAssignmentMode: ModelAssignmentMode = .separate
    /// Required when the mode is `SHARED`.
    public var sharedProfileID: String?
    /// `ModelTask` raw value -> profile ID. A missing key is an empty slot.
    public var separateProfiles: [String: String] = [:]
    /// At least one non-whitespace wording; content is kept verbatim.
    public var dataTypes: [String] = AnonymizationSettings.initialDataTypes

    public init() {}

    /// Mode-aware assignment of a task: the shared profile in `SHARED`, the
    /// task's own slot in `SEPARATE`.
    public func profileID(for task: ModelTask) -> String? {
        switch modelAssignmentMode {
        case .shared: return sharedProfileID
        case .separate: return separateProfiles[task.rawValue]
        }
    }

    /// Set or clear one separate slot. Slots never store empty strings: a nil
    /// id removes the key.
    public mutating func setSeparateProfile(_ profileID: String?, for task: ModelTask) {
        if let profileID, !profileID.isEmpty {
            separateProfiles[task.rawValue] = profileID
        } else {
            separateProfiles[task.rawValue] = nil
        }
    }

    /// The record with the two library-coupled slots mirroring the live native
    /// selections: in `SEPARATE` the summary and diagram assignments are the
    /// library's own selections, so the record keeps the last saved assignment
    /// of every task while the user manages the native pickers. A nil id
    /// clears the slot. Used when saving the draft and when computing removal
    /// plans; the anonymization slot is never touched here.
    public func syncingNativeAssignments(summaryID: String?, diagramID: String?) -> AnonymizationSettings {
        var synced = self
        synced.setSeparateProfile(summaryID, for: .summary)
        synced.setSeparateProfile(diagramID, for: .diagramRecognition)
        return synced
    }

    /// Drop whitespace-only lines, keeping every other line verbatim —
    /// including its internal and surrounding spaces. The saved order of the
    /// remaining lines is preserved.
    public static func sanitizeDataTypes(_ lines: [String]) -> [String] {
        lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Apply a draft list of type lines: whitespace-only lines are dropped and
    /// an empty remainder is rejected, keeping the active record untouched.
    public mutating func applyDataTypes(_ lines: [String]) throws {
        let sanitized = Self.sanitizeDataTypes(lines)
        guard !sanitized.isEmpty else { throw ScribeError.message("Укажите хотя бы один тип данных") }
        dataTypes = sanitized
    }

    public func validate() throws {
        guard schemaVersion == 1 else { throw ScribeError.message("Некорректная версия настроек обезличивания") }
        if let shared = sharedProfileID {
            guard ModelProfile.safeComponent(shared) else {
                throw ScribeError.message("Некорректное назначение модели в настройках обезличивания")
            }
        }
        if modelAssignmentMode == .shared, sharedProfileID == nil {
            throw ScribeError.message("В общем режиме нужен выбранный профиль")
        }
        let taskKeys = Set(ModelTask.allCases.map(\.rawValue))
        for (key, value) in separateProfiles {
            guard taskKeys.contains(key), ModelProfile.safeComponent(value) else {
                throw ScribeError.message("Некорректное назначение модели в настройках обезличивания")
            }
        }
        guard !dataTypes.isEmpty,
              dataTypes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ScribeError.message("Список типов данных не может быть пустым")
        }
    }
}

/// File storage of the settings record: one atomic JSON write per save, one
/// additive file that older versions never read or rewrite.
///
/// First open of the new version migrates: the record is created in `SEPARATE`
/// from the previous summary and diagram selections, with an empty
/// anonymization slot and shared profile and the initial data types. Later
/// opens read the saved record; a damaged record is reported and never
/// replaced. The old `selection.json` and UserDefaults keys stay untouched, so
/// a rollback keeps the old version's view intact and a return re-reads this
/// record.
public struct AnonymizationSettingsStore: Sendable {
    public let url: URL

    /// The record lives beside the archives of the application data root.
    public init(root: URL) {
        self.init(url: root.appendingPathComponent("anonymization").appendingPathComponent("settings.json"))
    }
    public init(url: URL) {
        self.url = url
    }

    /// Nil only when the record is absent. A damaged or undecodable record is
    /// an error and is never replaced with defaults.
    public func load() throws -> AnonymizationSettings? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let settings: AnonymizationSettings
        do { settings = try Disk.read(AnonymizationSettings.self, at: url) }
        catch { throw ScribeError.message("Не удалось прочитать настройки обезличивания: \(error.localizedDescription)") }
        do { try settings.validate() }
        catch { throw ScribeError.message("Повреждённая запись настроек обезличивания") }
        return settings
    }

    /// One atomic write of the whole validated record.
    public func save(_ settings: AnonymizationSettings) throws {
        try settings.validate()
        try Disk.write(settings, to: url)
    }

    /// The migration record from the previous summary and diagram selections:
    /// `SEPARATE`, empty anonymization slot and shared profile, initial data
    /// types. A previous selection only carries over while its profile exists
    /// in the current catalog; otherwise the slot stays empty.
    public static func migratedSettings(catalog: ModelCatalog, library: ModelLibrary) -> AnonymizationSettings {
        var settings = AnonymizationSettings()
        for task in ModelTask.allCases {
            guard let role = task.legacyRole,
                  let selected = library.selectedByRole[role.rawValue],
                  catalog.models.contains(where: { $0.id == selected }) else { continue }
            settings.setSeparateProfile(selected, for: task)
        }
        return settings
    }

    /// First open: create and persist the migration record. Later opens read
    /// the saved record as the single source of truth. Never writes any old
    /// keys of the previous version.
    public func loadOrMigrate(catalog: ModelCatalog, library: ModelLibrary) throws -> AnonymizationSettings {
        if let saved = try load() { return saved }
        let migrated = Self.migratedSettings(catalog: catalog, library: library)
        try save(migrated)
        return migrated
    }
}

/// One coordinated first open of the anonymization feature under the
/// application data root: the empty text archive (system group only) is
/// created by the repository, and the settings record is migrated in the same
/// open from the previous summary and diagram selections. Both are additive —
/// an old version rolled back keeps its own archives and settings untouched,
/// and both new locations survive the rollback to be read again on return.
/// The GUI keeps its own actors for transactions; this bootstrap only wires
/// the storage-level first open.
public enum AnonymizationBootstrap {
    public struct Opened: Sendable {
        public let repository: AnonymizationRepository
        public let settings: AnonymizationSettings
        /// True when this open created the settings record (first migration).
        public let settingsCreated: Bool
    }

    public static func open(root: URL, catalog: ModelCatalog, library: ModelLibrary) throws -> Opened {
        let repository = try AnonymizationRepository(root: root.appendingPathComponent("texts", isDirectory: true))
        let store = AnonymizationSettingsStore(root: root)
        let settingsCreated = !FileManager.default.fileExists(atPath: store.url.path)
        let settings = try store.loadOrMigrate(catalog: catalog, library: library)
        return Opened(repository: repository, settings: settings, settingsCreated: settingsCreated)
    }
}
