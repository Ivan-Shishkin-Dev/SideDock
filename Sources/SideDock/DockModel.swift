import AppKit
import Combine
import UniformTypeIdentifiers

extension UTType {
    /// Private drag type used to reorder icons inside SideDock (declared in Info.plist).
    static let sideDockItem = UTType(exportedAs: "com.local.sidedock.item")
}

struct DockItem: Identifiable, Equatable {
    enum Kind { case app, folder, file }

    let id: String          // path on disk
    let url: URL
    let name: String
    let kind: Kind
    var isRunning = false
    var isActive = false
    var isPinned = false
}

/// One file or folder shown inside a folder stack.
struct StackEntry: Identifiable, Equatable {
    var id: String { url.path }
    let url: URL
    let name: String
    let isFolder: Bool      // a plain folder you can browse into (not an .app or package)
}

enum StackSort: String { case name, dateAdded }
enum StackDisplay: String { case folder, stack }

/// Pinned items (apps, folders, files) are saved in UserDefaults; running apps come from NSWorkspace.
@MainActor
final class DockModel: ObservableObject {
    @Published private(set) var pinnedItems: [DockItem] = []
    @Published private(set) var runningItems: [DockItem] = []
    @Published private(set) var badges: [String: String] = [:]
    @Published private(set) var folderPreviews: [String: [StackEntry]] = [:]
    @Published var openStack: String?          // folder whose popover is open
    @Published var prefsVersion = 0            // bumps when folder settings change
    var dragging: String?                      // item being reordered

    private let pinKey = "pinnedApps"
    private var iconCache: [String: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []

    static let defaultPins = [
        "/System/Library/CoreServices/Finder.app",
        "/Applications/Safari.app",
        "/System/Applications/Utilities/Terminal.app",
        "/System/Applications/System Settings.app",
        NSHomeDirectory() + "/Downloads",
    ]

    var pinnedPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: pinKey) ?? Self.defaultPins }
        set { UserDefaults.standard.set(newValue, forKey: pinKey); refresh() }
    }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let me = Bundle.main.bundleURL.path
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleURL != nil && $0.bundleURL!.path != me
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleURL?.path
        let runningPaths = Set(running.compactMap { $0.bundleURL?.path })

        let pinned = pinnedPaths.filter { FileManager.default.fileExists(atPath: $0) }
        pinnedItems = pinned.map { path in
            var item = makeItem(path)
            item.isPinned = true
            item.isRunning = runningPaths.contains(path)
            item.isActive = path == frontmost
            return item
        }

        let pinnedSet = Set(pinned)
        var seen = Set<String>()
        runningItems = running.compactMap { app in
            guard let path = app.bundleURL?.path, !pinnedSet.contains(path), seen.insert(path).inserted else { return nil }
            var item = makeItem(path)
            item.isRunning = true
            item.isActive = path == frontmost
            return item
        }
        reloadFolderPreviews()
    }

    private func makeItem(_ path: String) -> DockItem {
        let url = URL(fileURLWithPath: path)
        let name = FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
        return DockItem(id: path, url: url, name: name, kind: Self.kind(of: url))
    }

    static func kind(of url: URL) -> DockItem.Kind {
        if url.pathExtension == "app" { return .app }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true && values?.isPackage != true { return .folder }
        return .file
    }

    func icon(for path: String) -> NSImage {
        if let cached = iconCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        iconCache[path] = image
        return image
    }

    // MARK: Folder stacks

    private func prefs(_ folder: String) -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: "folderPrefs")?[folder] as? [String: String]) ?? [:]
    }

    private func setPref(_ folder: String, _ key: String, _ value: String) {
        var all = UserDefaults.standard.dictionary(forKey: "folderPrefs") ?? [:]
        var mine = all[folder] as? [String: String] ?? [:]
        mine[key] = value
        all[folder] = mine
        UserDefaults.standard.set(all, forKey: "folderPrefs")
        prefsVersion += 1
        reloadFolderPreviews()
    }

    func sort(for folder: String) -> StackSort {
        StackSort(rawValue: prefs(folder)["sort"] ?? "")
            ?? (folder == NSHomeDirectory() + "/Downloads" ? .dateAdded : Prefs.shared.defaultSort)
    }
    func setSort(_ sort: StackSort, for folder: String) { setPref(folder, "sort", sort.rawValue) }

    func display(for folder: String) -> StackDisplay {
        StackDisplay(rawValue: prefs(folder)["display"] ?? "") ?? Prefs.shared.defaultDisplay
    }
    func setDisplay(_ display: StackDisplay, for folder: String) { setPref(folder, "display", display.rawValue) }

    /// Visible contents of a folder, sorted per that folder's setting.
    func contents(of folder: URL, sort: StackSort) -> [StackEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .addedToDirectoryDateKey, .localizedNameKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let entries: [(StackEntry, Date)] = urls.map { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isFolder = v?.isDirectory == true && v?.isPackage != true
            let name = (v?.localizedName ?? url.lastPathComponent).replacingOccurrences(of: ".app", with: "")
            return (StackEntry(url: url, name: name, isFolder: isFolder), v?.addedToDirectoryDate ?? .distantPast)
        }
        switch sort {
        case .name:
            return entries.map(\.0).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .dateAdded:
            return entries.sorted { $0.1 > $1.1 }.map(\.0)
        }
    }

    /// First few items of each pinned folder, used for the stacked icon.
    func reloadFolderPreviews() {
        var next: [String: [StackEntry]] = [:]
        for item in pinnedItems where item.kind == .folder {
            next[item.id] = Array(contents(of: item.url, sort: sort(for: item.id)).prefix(4))
        }
        if next != folderPreviews { folderPreviews = next }
    }

    // MARK: Badges

    func setBadges(_ new: [String: String]) {
        if new != badges { badges = new }
    }

    // MARK: Actions

    func activate(_ item: DockItem) {
        switch item.kind {
        case .folder:
            openStack = openStack == item.id ? nil : item.id
        case .app:
            openStack = nil
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: item.url, configuration: config)
        case .file:
            openStack = nil
            NSWorkspace.shared.open(item.url)
        }
    }

    func quit(_ item: DockItem) { runningApps(for: item).forEach { $0.terminate() } }
    func hide(_ item: DockItem) { runningApps(for: item).forEach { $0.hide() } }

    func showInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openInFinder(_ folder: URL) {
        NSWorkspace.shared.open(folder)
    }

    func pin(_ path: String, before target: String? = nil) {
        var paths = pinnedPaths
        paths.removeAll { $0 == path }
        if let target, let i = paths.firstIndex(of: target) {
            paths.insert(path, at: i)
        } else {
            paths.append(path)
        }
        pinnedPaths = paths
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var paths = pinnedItems.map(\.id)
        let moving = source.map { paths[$0] }
        let insertAt = destination - source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { paths.remove(at: index) }
        paths.insert(contentsOf: moving, at: insertAt)
        pinnedPaths = paths
    }

    func unpin(_ item: DockItem) {
        if openStack == item.id { openStack = nil }
        pinnedPaths.removeAll { $0 == item.id }
    }

    private func runningApps(for item: DockItem) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == item.id }
    }
}
