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

/// Neighbor lookup for Up/Down arrow navigation. `order` is the displayed
/// sidebar order, so collapsed groups, the current group order and an active
/// search filter are already reflected in it. With no visible current row
/// Down selects the first row and Up the last; the ends clamp (no wrap), and
/// a selection outside `order` (collapsed group, filtered out) counts as none.
enum SidebarNeighbor {
    static func next(current: String?, in order: [String], down: Bool) -> String? {
        guard !order.isEmpty else { return nil }
        guard let current, let index = order.firstIndex(of: current) else {
            return down ? order.first : order.last
        }
        let target = down ? index + 1 : index - 1
        guard order.indices.contains(target) else { return nil }
        return order[target]
    }
}
