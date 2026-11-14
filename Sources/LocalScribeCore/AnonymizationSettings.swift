import Foundation

/// Independent assignments for summaries, diagrams and anonymization, plus
/// the ordered data types. Speech recognition and diarization selections
/// stay in `ModelLibrary`.
public struct AnonymizationSettings: Codable, Equatable, Sendable {
    /// Initial data types of a fresh record (AC-27).
    public static let initialDataTypes = ["Имена и фамилии", "Телефоны", "Адреса электронной почты", "Почтовые адреса"]

    public var schemaVersion = 1
    /// `ModelTask` raw value -> profile ID. A missing key is an empty slot.
    public private(set) var profilesByTask: [String: String] = [:]
    /// At least one non-whitespace wording; content is kept verbatim.
    public var dataTypes: [String] = AnonymizationSettings.initialDataTypes

    public init() {}

    fileprivate struct Record: Codable {
        enum Mode: String, Codable {
            case separate = "SEPARATE"
            case shared = "SHARED"
        }

        var schemaVersion: Int
        var modelAssignmentMode: Mode
        var sharedProfileID: String?
        var separateProfiles: [String: String]
        var dataTypes: [String]
        var independentAssignments: Bool?

        init(settings: AnonymizationSettings) {
            // Keep the version 1 layout readable by older builds.
            schemaVersion = settings.schemaVersion
            modelAssignmentMode = .separate
            separateProfiles = settings.profilesByTask
            dataTypes = settings.dataTypes
            independentAssignments = true
        }
    }

    public init(from decoder: any Decoder) throws {
        try self.init(record: Record(from: decoder))
    }

    fileprivate init(record: Record) throws {
        schemaVersion = record.schemaVersion
        dataTypes = record.dataTypes
        try Self.validateProfiles(record.separateProfiles)
        if let shared = record.sharedProfileID, !ModelProfile.safeComponent(shared) {
            throw ScribeError.message("Некорректное назначение модели в настройках обезличивания")
        }
        switch record.modelAssignmentMode {
        case .separate:
            profilesByTask = record.separateProfiles
        case .shared:
            guard let shared = record.sharedProfileID else {
                throw ScribeError.message("В общем режиме нужен выбранный профиль")
            }
            for task in ModelTask.allCases { setProfile(shared, for: task) }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        try Record(settings: self).encode(to: encoder)
    }

    public func profileID(for task: ModelTask) -> String? {
        profilesByTask[task.rawValue]
    }

    /// Set or clear a task's slot. Empty IDs clear the slot.
    public mutating func setProfile(_ profileID: String?, for task: ModelTask) {
        if let profileID, !profileID.isEmpty {
            profilesByTask[task.rawValue] = profileID
        } else {
            profilesByTask[task.rawValue] = nil
        }
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
        try Self.validateProfiles(profilesByTask)
        guard !dataTypes.isEmpty,
              dataTypes.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ScribeError.message("Список типов данных не может быть пустым")
        }
    }

    private static func validateProfiles(_ profiles: [String: String]) throws {
        guard profiles.allSatisfy({ ModelTask(rawValue: $0.key) != nil && ModelProfile.safeComponent($0.value) }) else {
            throw ScribeError.message("Некорректное назначение модели в настройках обезличивания")
        }
    }
}

/// The task settings live in a separate file and are saved atomically.
/// First open copies the existing summary and diagram selections and sets
/// the initial data types. Later opens read the saved assignments, and report
/// a damaged record without replacing it.
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
        try loadRecord()?.settings
    }

    private func loadRecord() throws -> (record: AnonymizationSettings.Record, settings: AnonymizationSettings)? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let record: AnonymizationSettings.Record
        let settings: AnonymizationSettings
        do {
            record = try Disk.read(AnonymizationSettings.Record.self, at: url)
            settings = try AnonymizationSettings(record: record)
        } catch {
            throw ScribeError.message("Не удалось прочитать настройки обезличивания: \(error.localizedDescription)")
        }
        do { try settings.validate() }
        catch { throw ScribeError.message("Повреждённая запись настроек обезличивания") }
        return (record, settings)
    }

    /// One atomic write of the whole validated record.
    public func save(_ settings: AnonymizationSettings) throws {
        try settings.validate()
        try Disk.write(settings, to: url)
    }

    /// Copy the legacy summary and diagram selections whose profiles still
    /// exist in the catalog. The anonymization assignment starts empty.
    public static func migratedSettings(catalog: ModelCatalog, library: ModelLibrary) -> AnonymizationSettings {
        var settings = AnonymizationSettings()
        for task in ModelTask.allCases {
            guard let role = task.legacyRole,
                  let selected = library.selectedByRole[role.rawValue],
                  catalog.models.contains(where: { $0.id == selected }) else { continue }
            settings.setProfile(selected, for: task)
        }
        return settings
    }

    /// Migrate the old settings once. In the old separate mode the library was
    /// authoritative for summaries and diagrams, and their saved copies can be
    /// stale. A legacy shared profile has already been copied to each slot.
    public func loadOrMigrate(catalog: ModelCatalog, library: ModelLibrary) throws -> AnonymizationSettings {
        if let (record, saved) = try loadRecord() {
            if record.independentAssignments == true { return saved }
            var migrated = saved
            if record.modelAssignmentMode == .separate {
                let native = Self.migratedSettings(catalog: catalog, library: library)
                for task in ModelTask.allCases {
                    if let id = native.profileID(for: task) { migrated.setProfile(id, for: task) }
                }
            }
            try save(migrated)
            return migrated
        }
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
