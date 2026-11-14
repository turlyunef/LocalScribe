import Foundation

/// Kind of a text-archive group. Exactly one system group exists; its id and
/// name are fixed and it is always ordered last.
public enum AnonymizationGroupKind: String, Codable, Sendable {
    case user = "USER"
    case ungrouped = "UNGROUPED"
}

/// One group of the text archive. Names are unique case-insensitively; the
/// system group is protected from renaming, moving and deletion.
public struct AnonymizationGroup: Codable, Identifiable, Equatable, Sendable {
    public static let systemID = "00000000-0000-0000-0000-000000000000"
    public static let systemName = "Без темы"
    public let id: String
    public var kind: AnonymizationGroupKind
    public var name: String
    public var isExpanded: Bool
    public var isSystem: Bool { kind == .ungrouped }
    public var displayName: String { isSystem ? L10n.text(Self.systemName) : name }
    public init(id: String = UUID().uuidString, kind: AnonymizationGroupKind = .user,
                name: String, isExpanded: Bool = true) {
        self.id = id; self.kind = kind; self.name = name; self.isExpanded = isExpanded
    }
}

/// Authoritative catalog of the text archive (version 1): groups with their
/// order, the default group, card membership and the next import position
/// counter. Card documents never duplicate membership; the catalog is the
/// single source of truth for organization, exactly like the recording and
/// diagram group catalogs. A damaged catalog blocks group changes and is never
/// replaced with an empty one.
public struct AnonymizationArchiveCatalog: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    /// User groups in their saved order; the system group is always last.
    public private(set) var groups: [AnonymizationGroup]
    public private(set) var defaultGroupID: String
    /// Card UUID -> group UUID. Every imported card has an entry; a missing
    /// entry reads as the system group.
    public private(set) var membership: [String: String]
    /// Monotone counter of the next import position; deleting cards never
    /// moves it backwards.
    public private(set) var nextImportPosition: UInt
    public init() {
        groups = [AnonymizationGroup(id: AnonymizationGroup.systemID, kind: .ungrouped,
                                     name: AnonymizationGroup.systemName, isExpanded: true)]
        defaultGroupID = AnonymizationGroup.systemID
        membership = [:]
        nextImportPosition = 1
    }
    public func groupID(for cardID: String) -> String {
        membership[cardID] ?? AnonymizationGroup.systemID
    }
    public var defaultGroup: AnonymizationGroup? { groups.first { $0.id == defaultGroupID } }

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
        let system = groups.filter(\.isSystem)
        guard schemaVersion == 1, !groups.isEmpty, ids.count == groups.count,
              groups.allSatisfy({ UUID(uuidString: $0.id) != nil }),
              system.count == 1, groups.last?.isSystem == true,
              groups.last?.id == AnonymizationGroup.systemID,
              groups.last?.name == AnonymizationGroup.systemName,
              ids.contains(defaultGroupID),
              membership.allSatisfy({ UUID(uuidString: $0.key) != nil && ids.contains($0.value) }),
              nextImportPosition >= 1 else {
            throw ScribeError.message("Каталог текстового архива повреждён или создан другой версией приложения")
        }
        for group in groups {
            guard try validatedName(group.name, excluding: group.id) == group.name else {
                throw ScribeError.message("Некорректное название группы в каталоге текстового архива")
            }
            guard (group.id == AnonymizationGroup.systemID) == group.isSystem else {
                throw ScribeError.message("Некорректный признак системной группы в каталоге")
            }
        }
    }

    @discardableResult public mutating func create(name: String) throws -> AnonymizationGroup {
        let group = AnonymizationGroup(name: try validatedName(name))
        groups.insert(group, at: 0)
        defaultGroupID = group.id
        return group
    }
    public mutating func rename(_ id: String, name: String) throws {
        let index = try position(id)
        guard !groups[index].isSystem else { throw ScribeError.message("Нельзя переименовать «Без темы»") }
        groups[index].name = try validatedName(name, excluding: id)
    }
    public mutating func setDefault(_ id: String) throws { _ = try position(id); defaultGroupID = id }
    public mutating func setExpanded(_ id: String, _ expanded: Bool) throws {
        groups[try position(id)].isExpanded = expanded
    }
    public mutating func setAllExpanded(_ expanded: Bool) {
        for index in groups.indices where groups[index].isExpanded != expanded {
            groups[index].isExpanded = expanded
        }
    }
    public mutating func move(_ id: String, before target: String) throws {
        let source = try position(id); _ = try position(target)
        guard !groups[source].isSystem else { throw ScribeError.message("Нельзя переставить «Без темы»") }
        guard id != target else { return }
        let group = groups.remove(at: source)
        groups.insert(group, at: try position(target))
    }
    /// Explicit assignment, including the system group; unknown groups throw.
    public mutating func assign(_ cardID: String, to groupID: String) throws {
        _ = try position(groupID)
        guard UUID(uuidString: cardID) != nil else { throw ScribeError.message("Недопустимый идентификатор карточки") }
        membership[cardID] = groupID
    }
    public mutating func unassign(_ cardID: String) { membership[cardID] = nil }
    /// Consumes the next import position. The counter only moves forward:
    /// deleting cards never reuses a position.
    public mutating func consumeImportPosition() { nextImportPosition += 1 }
    /// Removes a user group. Remaining member references are dropped to the
    /// system group defensively; the default group falls back to «Без темы».
    public mutating func remove(_ id: String) throws {
        let index = try position(id)
        guard !groups[index].isSystem else { throw ScribeError.message("Нельзя удалить «Без темы»") }
        groups.remove(at: index)
        membership = membership.filter { $0.value != id }
        if defaultGroupID == id { defaultGroupID = AnonymizationGroup.systemID }
    }
    private func position(_ id: String) throws -> Int {
        guard let index = groups.firstIndex(where: { $0.id == id }) else {
            throw ScribeError.message("Группа больше не существует")
        }
        return index
    }
}
