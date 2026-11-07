import AppKit
import UniformTypeIdentifiers

/// UUID-payload transfer between sidebar sections. The drag type is supplied
/// by the caller, so any archive can declare its own internal types.
enum SidebarItemTransfer {
    static func provider(_ id: String, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(id.utf8)
        provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
    static func identifier(_ data: Data?) -> String? {
        guard let data, let id = String(data: data, encoding: .utf8), UUID(uuidString: id) != nil else { return nil }
        return id
    }
    @MainActor static func load(_ provider: NSItemProvider, type: UTType, perform: @escaping @MainActor (String) -> Void) {
        _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let id = identifier(data) else { return }
            Task { @MainActor in perform(id) }
        }
    }
}

/// Internal drag types of the recording archive.
enum SidebarTransferTypes {
    static let recording = UTType(exportedAs: "app.localscribe.recording", conformingTo: .data)
    static let group = UTType(exportedAs: "app.localscribe.group", conformingTo: .data)
}

/// Recording-facing facade over the shared transfer core.
enum SidebarTransfer {
    static let recording = SidebarTransferTypes.recording
    static let group = SidebarTransferTypes.group

    static func provider(_ id: String, type: UTType) -> NSItemProvider {
        SidebarItemTransfer.provider(id, type: type)
    }
    static func identifier(_ data: Data?) -> String? {
        SidebarItemTransfer.identifier(data)
    }
    @MainActor static func load(_ provider: NSItemProvider, type: UTType, perform: @escaping @MainActor (String) -> Void) {
        SidebarItemTransfer.load(provider, type: type, perform: perform)
    }
}
