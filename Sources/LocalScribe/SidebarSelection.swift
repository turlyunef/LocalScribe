import Foundation

/// Selection follows the displayed order, excluding rows in collapsed groups.
struct SidebarSelection: Equatable {
    var ids: Set<String> = []
    var anchor: String?

    init(_ id: String? = nil) {
        ids = Set(id.map { [$0] } ?? [])
        anchor = id
    }

    mutating func click(_ id: String, command: Bool, shift: Bool, order: [String]) {
        if shift, let anchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
            let range = Set(order[min(start, end)...max(start, end)])
            ids = command ? ids.union(range) : range
        } else if command {
            if !ids.insert(id).inserted { ids.remove(id) }
            anchor = id
        } else {
            self = SidebarSelection(id)
        }
    }

    mutating func contextClick(_ id: String) {
        if !ids.contains(id) { self = SidebarSelection(id) }
    }

    mutating func retain(_ existing: Set<String>) {
        ids.formIntersection(existing)
        if let anchor, !existing.contains(anchor) { self.anchor = nil }
    }
}
