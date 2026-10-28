import AppKit
import Combine
import UniformTypeIdentifiers

extension UTType {
    /// Private drag type used to reorder icons inside SideDock (declared in Info.plist).
    static let sideDockItem = UTType(exportedAs: "com.local.sidedock.item")
}

struct DockItem: Identifiable, Equatable {
    enum Kind { case app, folder, file, group }

    let id: String          // path on disk, or "group:<uuid>" for an app group
    let url: URL
    let name: String
    let kind: Kind
    var isRunning = false
    var isActive = false
    var isPinned = false
    var members: [String] = []   // app paths, for groups only
}

/// A named set of apps shown as one dock icon.
struct AppGroup: Codable, Equatable {
    var name: String
    var apps: [String]
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
    @Published var openStack: String?          // folder or group whose popover is open
    @Published var mergeTarget: String?        // icon highlighted while an app is dragged onto it
    @Published var hoveredID: String?
    @Published private(set) var trashFull = false          // icon under the pointer (cleared when the dock hides)
    @Published private(set) var groups: [String: AppGroup] = DockModel.loadGroups()
    @Published private(set) var aero = AeroSpace.Snapshot()
    @Published private(set) var frontmostPath: String?   // AeroSpace workspace per app
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
        if frontmost != frontmostPath { frontmostPath = frontmost }
        let runningPaths = Set(running.compactMap { $0.bundleURL?.path })

        let pinned = pinnedPaths.filter { Self.isGroup($0) ? groups[$0] != nil : FileManager.default.fileExists(atPath: $0) }
        pinnedItems = pinned.map { path in
            if let group = groups[path] {
                let apps = group.apps.filter { FileManager.default.fileExists(atPath: $0) }
                return DockItem(id: path, url: URL(fileURLWithPath: NSHomeDirectory()), name: group.name, kind: .group,
                                isRunning: apps.contains(where: runningPaths.contains),
                                isActive: frontmost.map(apps.contains) ?? false,
                                isPinned: true, members: apps)
            }
            var item = makeItem(path)
            item.isPinned = true
            item.isRunning = runningPaths.contains(path)
            item.isActive = path == frontmost
            return item
        }

        // Apps inside a group show on the group's icon, not again in the running section.
        let grouped = pinnedItems.flatMap(\.members)
        let pinnedSet = Set(pinned).union(grouped)
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
        updateTrash()
    }

    // MARK: Trash

    var trashURL: URL {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
    }

    var trashIcon: NSImage {
        NSImage(named: trashFull ? NSImage.trashFullName : NSImage.trashEmptyName)
            ?? NSWorkspace.shared.icon(forFile: trashURL.path)
    }

    /// Full/empty icon. If macOS won't let SideDock look inside the Trash, it shows as empty.
    func updateTrash() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: trashURL.path)) ?? []
        let full = names.contains { $0 != ".DS_Store" }
        if full != trashFull { trashFull = full }
    }

    func openTrash() {
        openStack = nil
        NSWorkspace.shared.open(trashURL)
    }

    /// Moves a file to the Trash (recoverable, same as ⌘⌫ in Finder).
    func moveToTrash(_ url: URL) {
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSSound.beep()
        }
        trashFull = true
        refresh()
    }

    /// Asks first, then has Finder empty the Trash. This deletes files for good.
    func emptyTrash() {
        let alert = NSAlert()
        alert.messageText = "Empty the Trash?"
        alert.informativeText = "Items in the Trash will be deleted immediately. You can't undo this."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Empty Trash")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Finder\" to empty trash")?.executeAndReturnError(&error)
        updateTrash()
    }

    /// Removes an icon from SideDock without touching the file on disk.
    func removeFromDock(_ id: String) {
        if let item = pinnedItems.first(where: { $0.id == id }) {
            unpin(item)
        } else if let groupID = groups.first(where: { $0.value.apps.contains(id) })?.key {
            removeFromGroup(id, groupID)
            pinnedPaths.removeAll { $0 == id }
        }
    }

    // MARK: Badges

    func setBadges(_ new: [String: String]) {
        if new != badges { badges = new }
    }

    func setAero(_ new: AeroSpace.Snapshot) {
        if new != aero { aero = new }
    }

    /// True once AeroSpace has reported in; then an app with no workspace counts as closed.
    var aeroActive: Bool { Prefs.shared.showWorkspaces && !aero.workspaces.isEmpty }

    /// Workspaces holding this item's windows (for a group: all its apps).
    func workspaces(for item: DockItem) -> [String] {
        let paths = item.kind == .group ? item.members : [item.id]
        var out: [String] = []
        for path in paths { for ws in aero.workspaces[path] ?? [] where !out.contains(ws) { out.append(ws) } }
        return out
    }

    // MARK: Actions

    func activate(_ item: DockItem) {
        switch item.kind {
        case .folder, .group:
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
        if item.kind == .group { setGroup(item.id, nil) }
        pinnedPaths.removeAll { $0 == item.id }
    }

    // MARK: App groups

    static func isGroup(_ id: String) -> Bool { id.hasPrefix("group:") }

    private static func loadGroups() -> [String: AppGroup] {
        guard let data = UserDefaults.standard.data(forKey: "appGroups") else { return [:] }
        return (try? JSONDecoder().decode([String: AppGroup].self, from: data)) ?? [:]
    }

    private func setGroup(_ id: String, _ group: AppGroup?) {
        groups[id] = group
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: "appGroups")
        }
    }

    var groupList: [(id: String, name: String)] {
        pinnedItems.filter { $0.kind == .group }.map { ($0.id, $0.name) }
    }

    /// Makes a new group from `apps`, placed where `target` (or the first app) sits in the dock.
    @discardableResult
    func createGroup(with apps: [String], name: String = "Apps", at target: String? = nil) -> String {
        let id = "group:" + UUID().uuidString
        var unique: [String] = []
        for app in apps where !unique.contains(app) { unique.append(app) }
        setGroup(id, AppGroup(name: name, apps: unique))
        var paths = pinnedPaths
        let anchor = target ?? unique.first
        let index = anchor.flatMap { paths.firstIndex(of: $0) } ?? paths.count
        paths.insert(id, at: index)
        paths.removeAll { unique.contains($0) }
        pinnedPaths = paths
        return id
    }

    /// Moves a dock item just before or after another one. No-op if nothing would change.
    func place(_ id: String, relativeTo target: String, before: Bool) {
        let old = pinnedPaths
        var paths = old.filter { $0 != id }
        guard let i = paths.firstIndex(of: target) else { return }
        paths.insert(id, at: before ? i : i + 1)
        if paths != old { pinnedPaths = paths }
    }

    /// Drops `app` onto `target`: joins the target's group, or makes a new group from both apps.
    func merge(_ app: String, into target: DockItem) {
        guard app != target.id else { return }
        if target.kind == .group {
            addToGroup(app, target.id)
        } else if let existing = groups.first(where: { $0.value.apps.contains(target.id) })?.key {
            addToGroup(app, existing)
        } else {
            createGroup(with: [target.id, app], at: target.id)
        }
    }

    func addToGroup(_ app: String, _ groupID: String) {
        guard var group = groups[groupID], !group.apps.contains(app) else { return }
        group.apps.append(app)
        setGroup(groupID, group)
        pinnedPaths = pinnedPaths.filter { $0 != app }
    }

    /// Takes an app out of a group and puts it back in the dock right after the group.
    func removeFromGroup(_ app: String, _ groupID: String) {
        guard var group = groups[groupID] else { return }
        group.apps.removeAll { $0 == app }
        var paths = pinnedPaths
        if let i = paths.firstIndex(of: groupID) { paths.insert(app, at: i + 1) }
        if group.apps.isEmpty {
            paths.removeAll { $0 == groupID }
            setGroup(groupID, nil)
        } else {
            setGroup(groupID, group)
        }
        pinnedPaths = paths
    }

    /// Breaks a group apart, putting its apps back in the dock where it was.
    func ungroup(_ groupID: String) {
        guard let group = groups[groupID] else { return }
        if openStack == groupID { openStack = nil }
        var paths = pinnedPaths.filter { !group.apps.contains($0) }
        if let i = paths.firstIndex(of: groupID) {
            paths.replaceSubrange(i...i, with: group.apps)
        }
        setGroup(groupID, nil)
        pinnedPaths = paths
    }

    func renameGroup(_ groupID: String, to name: String) {
        guard var group = groups[groupID], !name.isEmpty else { return }
        group.name = name
        setGroup(groupID, group)
        refresh()
    }

    /// Asks for a new group name in a small dialog.
    func promptRename(_ groupID: String) {
        guard let group = groups[groupID] else { return }
        openStack = nil
        let alert = NSAlert()
        alert.messageText = "Rename Group"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: group.name)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            renameGroup(groupID, to: field.stringValue.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Combined badge for a group: the sum of number badges, or a dot for other kinds.
    func groupBadge(_ item: DockItem) -> String? {
        let labels = item.members.compactMap { badges[$0] }
        guard !labels.isEmpty else { return nil }
        let numbers = labels.compactMap(Int.init)
        return numbers.count == labels.count ? String(numbers.reduce(0, +)) : "•"
    }

    func openApp(_ path: String) {
        openStack = nil
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: config)
    }

    func isRunning(_ path: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.path == path }
    }

    private func runningApps(for item: DockItem) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == item.id }
    }
}
