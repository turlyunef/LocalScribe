import Foundation

public struct RecordingGroup: Codable, Identifiable, Equatable, Sendable {
    public static let ungroupedID = "00000000-0000-0000-0000-000000000000"
    public let id: String
    public var name: String
    public var expanded: Bool
    public var isSystem: Bool { id == Self.ungroupedID }

    public init(id: String = UUID().uuidString, name: String, expanded: Bool = true) {
        self.id = id; self.name = name; self.expanded = expanded
    }
}

/// Authoritative metadata, independent of the derived index and processing manifests.
/// Missing membership means «Без темы», including every pre-groups archive.
public struct RecordingGroups: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public private(set) var groups = [RecordingGroup(id: RecordingGroup.ungroupedID, name: "Без темы")]
    public private(set) var defaultID = RecordingGroup.ungroupedID
    public private(set) var membership: [String: String] = [:]
    public init() {}
    public func groupID(for recordingID: String) -> String { membership[recordingID] ?? RecordingGroup.ungroupedID }
    public var defaultGroup: RecordingGroup { groups.first { $0.id == defaultID }! }

    public func validatedName(_ name: String, excluding id: String? = nil) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ScribeError.message("Введите название группы") }
        guard !groups.contains(where: { $0.id != id && $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) else {
            throw ScribeError.message("Группа с таким названием уже существует")
        }
        return name
    }
    public func validate() throws {
        let ids = Set(groups.map(\.id))
        guard schemaVersion == 1, !groups.isEmpty, ids.count == groups.count,
              groups.allSatisfy({ UUID(uuidString: $0.id) != nil }),
              groups.last?.id == RecordingGroup.ungroupedID, groups.last?.name == "Без темы",
              ids.contains(defaultID), membership.allSatisfy({ UUID(uuidString: $0.key) != nil && ids.contains($0.value) }) else {
            throw ScribeError.message("Каталог групп повреждён или создан другой версией приложения")
        }
        for group in groups {
            guard try validatedName(group.name, excluding: group.id) == group.name else {
                throw ScribeError.message("Некорректное название в каталоге групп")
            }
        }
    }
    @discardableResult public mutating func create(name: String) throws -> RecordingGroup {
        let group = RecordingGroup(name: try validatedName(name))
        groups.insert(group, at: 0); defaultID = group.id
        return group
    }
    public mutating func rename(_ id: String, name: String) throws {
        let index = try position(id)
        guard !groups[index].isSystem else { throw ScribeError.message("Нельзя переименовать «Без темы»") }
        groups[index].name = try validatedName(name, excluding: id)
    }
    public mutating func setDefault(_ id: String) throws { _ = try position(id); defaultID = id }
    public mutating func setExpanded(_ id: String, _ expanded: Bool) throws { groups[try position(id)].expanded = expanded }
    public mutating func move(_ id: String, before target: String) throws {
        let source = try position(id); _ = try position(target)
        guard !groups[source].isSystem else { throw ScribeError.message("Нельзя переставить «Без темы»") }
        guard id != target else { return }
        let group = groups.remove(at: source)
        groups.insert(group, at: try position(target))
    }
    public mutating func assign(_ recordingID: String, to id: String) throws {
        _ = try position(id)
        guard UUID(uuidString: recordingID) != nil else { throw ScribeError.message("Недопустимый идентификатор записи") }
        membership[recordingID] = id == RecordingGroup.ungroupedID ? nil : id
    }
    public mutating func remove(_ id: String) throws {
        let index = try position(id)
        guard !groups[index].isSystem else { throw ScribeError.message("Нельзя удалить «Без темы»") }
        groups.remove(at: index)
        membership = membership.filter { $0.value != id }
        if defaultID == id { defaultID = RecordingGroup.ungroupedID }
    }
    private func position(_ id: String) throws -> Int {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { throw ScribeError.message("Группа больше не существует") }
        return index
    }
}

extension RecordingRepository {
    public func loadGroups() throws -> RecordingGroups {
        let url = root.appendingPathComponent("groups.json")
        // Only ENOENT is a legacy archive. Permission/decoding errors must not reset metadata.
        do {
            let groups = try Disk.read(RecordingGroups.self, at: url)
            try groups.validate()
            return groups
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return RecordingGroups() }
    }
    public func saveGroups(_ groups: RecordingGroups) throws {
        try groups.validate()
        try Disk.write(groups, to: root.appendingPathComponent("groups.json"))
    }
}
