import AppKit
import Combine

enum DockEdge: String, CaseIterable, Identifiable {
    case left, right
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum DockPosition: String, CaseIterable, Identifiable {
    case top, center, bottom
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum DockMaterial: String, CaseIterable, Identifiable {
    case hud, sidebar, menu, popover, underWindow, fullScreen
    var id: Self { self }
    var title: String {
        switch self {
        case .hud: "Dark Glass"
        case .sidebar: "Sidebar"
        case .menu: "Menu"
        case .popover: "Popover"
        case .underWindow: "Subtle"
        case .fullScreen: "Frosted"
        }
    }
    var ns: NSVisualEffectView.Material {
        switch self {
        case .hud: .hudWindow
        case .sidebar: .sidebar
        case .menu: .menu
        case .popover: .popover
        case .underWindow: .underWindowBackground
        case .fullScreen: .fullScreenUI
        }
    }
}

/// Every SideDock setting, saved to UserDefaults as soon as it changes.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private static let d = UserDefaults.standard

    private static func load<T>(_ key: String, _ fallback: T) -> T {
        d.object(forKey: key) as? T ?? fallback
    }
    private static func loadEnum<T: RawRepresentable>(_ key: String, _ fallback: T) -> T where T.RawValue == String {
        T(rawValue: d.string(forKey: key) ?? "") ?? fallback
    }
    private func save(_ value: Any, _ key: String) { Self.d.set(value, forKey: key) }

    // General
    @Published var edge: DockEdge = loadEnum("edge", .left) { didSet { save(edge.rawValue, "edge") } }
    @Published var position: DockPosition = loadEnum("position", .center) { didSet { save(position.rawValue, "position") } }
    @Published var showMenuBarIcon: Bool = load("showMenuBarIcon", true) { didSet { save(showMenuBarIcon, "showMenuBarIcon") } }
    @Published var showRunningApps: Bool = load("showRunningApps", true) { didSet { save(showRunningApps, "showRunningApps") } }
    @Published var showTrash: Bool = load("showTrash", true) { didSet { save(showTrash, "showTrash") } }
    @Published var clickActiveToHide: Bool = load("clickActiveToHide", false) { didSet { save(clickActiveToHide, "clickActiveToHide") } }

    // Appearance
    @Published var iconSize: Double = load("iconSize", 44) { didSet { save(iconSize, "iconSize") } }
    @Published var spacing: Double = load("spacing", 6) { didSet { save(spacing, "spacing") } }
    @Published var magnify: Bool = load("magnify", true) { didSet { save(magnify, "magnify") } }
    @Published var magnifyAmount: Double = load("magnifyAmount", 1.2) { didSet { save(magnifyAmount, "magnifyAmount") } }
    @Published var cornerRadius: Double = load("cornerRadius", 18) { didSet { save(cornerRadius, "cornerRadius") } }
    @Published var edgeGap: Double = load("edgeGap", 6) { didSet { save(edgeGap, "edgeGap") } }
    @Published var material: DockMaterial = loadEnum("material", .hud) { didSet { save(material.rawValue, "material") } }
    @Published var showIndicators: Bool = load("showIndicators", true) { didSet { save(showIndicators, "showIndicators") } }
    @Published var showTooltips: Bool = load("showTooltips", true) { didSet { save(showTooltips, "showTooltips") } }

    // Behavior
    @Published var autoHide: Bool = load("autoHide", true) { didSet { save(autoHide, "autoHide") } }
    @Published var revealDelay: Double = load("revealDelay", 0) { didSet { save(revealDelay, "revealDelay") } }
    @Published var hideDelay: Double = load("hideDelay", 0.4) { didSet { save(hideDelay, "hideDelay") } }
    @Published var animationDuration: Double = load("animationDuration", 0.18) { didSet { save(animationDuration, "animationDuration") } }

    // Folders
    @Published var defaultSort: StackSort = loadEnum("defaultSort", .name) { didSet { save(defaultSort.rawValue, "defaultSort") } }
    @Published var defaultDisplay: StackDisplay = loadEnum("defaultDisplay", .stack) { didSet { save(defaultDisplay.rawValue, "defaultDisplay") } }
    @Published var stackColumns: Double = load("stackColumns", 4) { didSet { save(stackColumns, "stackColumns") } }

    // AeroSpace
    @Published var showWorkspaces: Bool = load("showWorkspaces", true) { didSet { save(showWorkspaces, "showWorkspaces") } }

    // Badges
    @Published var showBadges: Bool = load("showBadges", false) { didSet { save(showBadges, "showBadges") } }

    /// Clears every setting (pinned items stay).
    func resetAll() {
        let keys = ["edge", "position", "showMenuBarIcon", "showRunningApps", "showTrash", "clickActiveToHide", "iconSize",
                    "spacing", "magnify", "magnifyAmount", "cornerRadius", "edgeGap", "material", "showIndicators",
                    "showTooltips", "autoHide", "revealDelay", "hideDelay", "animationDuration", "defaultSort",
                    "defaultDisplay", "stackColumns", "showBadges", "showWorkspaces"]
        keys.forEach { Self.d.removeObject(forKey: $0) }
        edge = .left; position = .center; showMenuBarIcon = true; showRunningApps = true; showTrash = true; clickActiveToHide = false
        iconSize = 44; spacing = 6; magnify = true; magnifyAmount = 1.2; cornerRadius = 18; edgeGap = 6
        material = .hud; showIndicators = true; showTooltips = true
        autoHide = true; revealDelay = 0; hideDelay = 0.4; animationDuration = 0.18
        defaultSort = .name; defaultDisplay = .stack; stackColumns = 4; showBadges = false; showWorkspaces = true
    }
}
