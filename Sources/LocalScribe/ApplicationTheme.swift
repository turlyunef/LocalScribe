import AppKit
import LocalScribeCore

enum ApplicationTheme: String, CaseIterable {
    case system
    case light
    case dark

    static let defaultsKey = "applicationTheme"

    static func selection(in defaults: UserDefaults) -> Self {
        defaults.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .system
    }

    var title: String {
        switch self {
        case .system: return L10n.text("Как в системе")
        case .light: return L10n.text("Светлая")
        case .dark: return L10n.text("Тёмная")
        }
    }

    /// `nil` follows the system appearance.
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    @MainActor func apply() { NSApp.appearance = appearance }
}
