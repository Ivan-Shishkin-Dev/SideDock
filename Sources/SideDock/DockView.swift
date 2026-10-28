import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct DockView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var prefs: Prefs

    /// Extra room on the inner side so magnified icons aren't clipped.
    private var magnifyRoom: CGFloat {
        prefs.magnify ? prefs.iconSize * (prefs.magnifyAmount - 1) : 0
    }

    var body: some View {
        VStack(spacing: prefs.spacing) {
            if prefs.showTrash {
                TrashIcon(model: model, prefs: prefs)
            }
            ForEach(model.pinnedItems) { item in
                DockIcon(item: item, model: model, prefs: prefs)
            }
            if prefs.showRunningApps && !model.runningItems.isEmpty {
                if !model.pinnedItems.isEmpty {
                    Capsule().fill(.secondary.opacity(0.5))
                        .frame(width: prefs.iconSize * 0.7, height: 1)
                        .padding(.vertical, 2)
                }
                ForEach(model.runningItems) { item in
                    DockIcon(item: item, model: model, prefs: prefs)
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .padding(prefs.edge == .left ? .trailing : .leading, magnifyRoom)
        .fixedSize()
        .contentShape(Rectangle())
        .onDrop(of: [.fileURL, .sideDockItem], delegate: ItemDrop(target: nil, model: model, height: 0))
    }
}

// MARK: - Icon

struct DockIcon: View {
    let item: DockItem
    @ObservedObject var model: DockModel
    @ObservedObject var prefs: Prefs

    private var size: CGFloat { prefs.iconSize }
    private var hovering: Bool { model.hoveredID == item.id }

    private var stackOpen: Binding<Bool> {
        Binding(get: { model.openStack == item.id },
                set: { if !$0, model.openStack == item.id { model.openStack = nil } })
    }

    var body: some View {
        HStack(spacing: 3) {
            if prefs.edge == .left { dot }
            iconImage
                .frame(width: size, height: size)
                .background { mergeRing }
                .overlay(alignment: .topTrailing) { badge }
                .scaleEffect(hovering && prefs.magnify ? prefs.magnifyAmount : 1,
                             anchor: prefs.edge == .left ? .leading : .trailing)
                .animation(.spring(response: 0.2, dampingFraction: 0.82), value: hovering)
            if prefs.edge == .right { dot }
        }
        .zIndex(hovering ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hoveredID = item.id } else if model.hoveredID == item.id { model.hoveredID = nil }
        }
        .onTapGesture { click() }
        .onDrag {
            model.dragging = item.id
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.sideDockItem.identifier,
                                                visibility: .ownProcess) { done in
                done(Data(item.id.utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [.fileURL, .sideDockItem], delegate: ItemDrop(target: item, model: model, height: size))
        .help(prefs.showTooltips ? item.name : "")
        .popover(isPresented: stackOpen, arrowEdge: prefs.edge == .left ? .trailing : .leading) {
            if item.kind == .group {
                GroupView(item: item, model: model, prefs: prefs)
            } else {
                StackView(root: item.url, model: model, prefs: prefs)
            }
        }
        .contextMenu { menu }
    }

    private func click() {
        if item.kind == .app && item.isActive && prefs.clickActiveToHide {
            model.hide(item)
        } else {
            model.activate(item)
        }
    }

    @ViewBuilder private var iconImage: some View {
        if item.kind == .group {
            StackPreview(urls: item.members.prefix(4).map { URL(fileURLWithPath: $0) }, size: size)
        } else if item.kind == .folder, model.display(for: item.id) == .stack,
           let entries = model.folderPreviews[item.id], !entries.isEmpty {
            StackPreview(urls: entries.map(\.url), size: size)
        } else {
            Image(nsImage: model.icon(for: item.id)).resizable().interpolation(.high)
        }
    }

    /// Ring shown while an app is held over this icon to make (or add to) a group.
    @ViewBuilder private var mergeRing: some View {
        if model.mergeTarget == item.id {
            RoundedRectangle(cornerRadius: size * 0.26)
                .strokeBorder(Color.accentColor, lineWidth: 2.5)
                .background(RoundedRectangle(cornerRadius: size * 0.26).fill(Color.accentColor.opacity(0.18)))
                .padding(-4)
        }
    }

    private var badgeText: String? {
        item.kind == .group ? model.groupBadge(item) : model.badges[item.id]
    }

    @ViewBuilder private var badge: some View {
        if prefs.showBadges, let text = badgeText {
            Text(text)
                .font(.system(size: max(9, size * 0.24), weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .frame(minWidth: size * 0.36, minHeight: size * 0.36)
                .background(Capsule().fill(Color.red))
                .offset(x: 4, y: -4)
        }
    }

    private var dot: some View {
        Circle()
            .fill(item.isActive ? Color.accentColor : Color.primary.opacity(0.7))
            .frame(width: 4, height: 4)
            .opacity(item.isRunning && prefs.showIndicators ? 1 : 0)
    }

    @ViewBuilder private var menu: some View {
        Text(item.name)
        Divider()
        if item.kind == .folder {
            Button("Open in Finder") { model.openInFinder(item.url) }
            Picker("Sort By", selection: Binding(get: { model.sort(for: item.id) },
                                                 set: { model.setSort($0, for: item.id) })) {
                Text("Name").tag(StackSort.name)
                Text("Date Added").tag(StackSort.dateAdded)
            }
            Picker("Display As", selection: Binding(get: { model.display(for: item.id) },
                                                    set: { model.setDisplay($0, for: item.id) })) {
                Text("Folder").tag(StackDisplay.folder)
                Text("Stack").tag(StackDisplay.stack)
            }
            Divider()
        }
        if item.kind == .group {
            Button("Rename Group…") { model.promptRename(item.id) }
            Button("Ungroup") { model.ungroup(item.id) }
            Button("Remove Group from Dock") { model.unpin(item) }
        } else {
            if item.kind == .app {
                Menu("Add to Group") {
                    ForEach(model.groupList, id: \.id) { group in
                        Button(group.name) { model.addToGroup(item.id, group.id) }
                    }
                    if !model.groupList.isEmpty { Divider() }
                    Button("New Group") { model.createGroup(with: [item.id]) }
                }
            }
            if item.isPinned {
                Button("Remove from Dock") { model.unpin(item) }
            } else {
                Button("Keep in Dock") { model.pin(item.id) }
            }
            Button("Show in Finder") { model.showInFinder(item.url) }
        }
        if item.isRunning {
            Divider()
            Button("Hide") { model.hide(item) }
            Button("Quit") { model.quit(item) }
        }
        Divider()
        Button("SideDock Settings…") { NotificationCenter.default.post(name: .openSideDockSettings, object: nil) }
    }
}

extension Notification.Name {
    static let openSideDockSettings = Notification.Name("openSideDockSettings")
}

// MARK: - Trash

/// Click to open the Trash. Drop files on it to move them to the Trash.
/// Dropping a dock icon on it only removes that icon from SideDock.
struct TrashIcon: View {
    @ObservedObject var model: DockModel
    @ObservedObject var prefs: Prefs
    @State private var targeted = false

    private var size: CGFloat { prefs.iconSize }
    private var hovering: Bool { model.hoveredID == "trash" }

    var body: some View {
        HStack(spacing: 3) {
            if prefs.edge == .left { Color.clear.frame(width: 4, height: 4) }
            Image(nsImage: model.trashIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .background {
                    if targeted {
                        RoundedRectangle(cornerRadius: size * 0.26)
                            .fill(Color.accentColor.opacity(0.2))
                            .padding(-4)
                    }
                }
                .scaleEffect((hovering || targeted) && prefs.magnify ? prefs.magnifyAmount : 1,
                             anchor: prefs.edge == .left ? .leading : .trailing)
                .animation(.spring(response: 0.2, dampingFraction: 0.82), value: hovering || targeted)
            if prefs.edge == .right { Color.clear.frame(width: 4, height: 4) }
        }
        .zIndex(hovering ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.hoveredID = "trash" } else if model.hoveredID == "trash" { model.hoveredID = nil }
        }
        .onTapGesture { model.openTrash() }
        .onDrop(of: [.fileURL, .sideDockItem], isTargeted: $targeted) { providers in
            if let dragged = model.dragging {
                model.removeFromDock(dragged)
                model.dragging = nil
                return true
            }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.moveToTrash(url) }
                }
            }
            return true
        }
        .help(prefs.showTooltips ? "Trash" : "")
        .contextMenu {
            Button("Open Trash") { model.openTrash() }
            Button("Empty Trash…") { model.emptyTrash() }
        }
    }
}

// MARK: - Drag and drop

/// Handles drops on the dock:
/// - an app held over the middle of another app (or a group) makes or joins a group,
/// - over the top/bottom half it reorders,
/// - apps, folders or files from Finder get kept in the dock.
struct ItemDrop: DropDelegate {
    let target: DockItem?   // nil = empty area (append to the end)
    let model: DockModel
    let height: CGFloat

    private func isInternal(_ info: DropInfo) -> Bool { info.hasItemsConforming(to: [.sideDockItem]) }

    private func wantsMerge(_ info: DropInfo) -> Bool {
        guard let target, target.isPinned, target.kind == .app || target.kind == .group, height > 0 else { return false }
        let y = info.location.y
        guard y > height * 0.2 && y < height * 0.8 else { return false }
        if isInternal(info) {
            guard let dragged = model.dragging else { return false }
            return dragged.hasSuffix(".app") && dragged != target.id
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.sideDockItem, .fileURL])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let target, wantsMerge(info) {
            if model.mergeTarget != target.id { model.mergeTarget = target.id }
            return DropProposal(operation: .copy)
        }
        if model.mergeTarget != nil { model.mergeTarget = nil }
        if isInternal(info), let dragged = model.dragging, let target, target.isPinned, dragged != target.id {
            let before = info.location.y < height / 2
            withAnimation(.easeInOut(duration: 0.15)) { model.place(dragged, relativeTo: target.id, before: before) }
        }
        return DropProposal(operation: isInternal(info) ? .move : .copy)
    }

    func dropExited(info: DropInfo) {
        if let target, model.mergeTarget == target.id { model.mergeTarget = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let merging = target != nil && model.mergeTarget == target?.id
        model.mergeTarget = nil
        if isInternal(info) {
            defer { model.dragging = nil }
            if merging, let dragged = model.dragging, let target {
                model.merge(dragged, into: target)
            } else if let dragged = model.dragging, target?.isPinned != true, !model.pinnedPaths.contains(dragged) {
                model.pin(dragged)   // a running app dragged into the dock gets kept
            }
            return true
        }
        let before = target?.isPinned == true ? target?.id : nil
        for provider in info.itemProviders(for: [.fileURL]) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    if merging, let target, url.pathExtension == "app" {
                        model.merge(url.path, into: target)
                    } else {
                        model.pin(url.path, before: before)
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Folder stacks and groups

/// 2x2 grid of icons, like the macOS Dock's stack icon. Used for folders and app groups.
struct StackPreview: View {
    let urls: [URL]
    let size: CGFloat

    var body: some View {
        let cell = (size - 10) / 2
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(Color.primary.opacity(0.12))
            .overlay {
                LazyVGrid(columns: [GridItem(.fixed(cell), spacing: 3), GridItem(.fixed(cell), spacing: 3)], spacing: 3) {
                    ForEach(urls, id: \.self) { FileIcon(url: $0, size: cell) }
                }
            }
    }
}

/// Popover for an app group: click to open, right-click to remove, drop apps on it to add.
struct GroupView: View {
    let item: DockItem
    @ObservedObject var model: DockModel
    @ObservedObject var prefs: Prefs
    private let tile: CGFloat = 84

    var body: some View {
        let columns = max(2, min(Int(prefs.stackColumns), item.members.count))
        let rows = (item.members.count + columns - 1) / columns
        VStack(spacing: 0) {
            HStack {
                Text(item.name).font(.headline)
                Spacer()
                Button { model.promptRename(item.id) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .help("Rename group")
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 8), count: columns), spacing: 10) {
                    ForEach(item.members, id: \.self) { path in
                        GroupAppTile(path: path, groupID: item.id, model: model, showBadge: prefs.showBadges)
                    }
                }
                .padding(12)
            }
            .frame(height: min(CGFloat(max(rows, 1)) * 112 + 24, 440))
            Divider()
            Text("Drop apps here to add them").font(.caption).foregroundStyle(.secondary).padding(8)
        }
        .frame(width: CGFloat(columns) * tile + CGFloat(columns - 1) * 8 + 24)
        .onDrop(of: [.fileURL, .sideDockItem], isTargeted: nil) { providers in
            if let dragged = model.dragging, dragged.hasSuffix(".app") {
                model.addToGroup(dragged, item.id)
                model.dragging = nil
                return true
            }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.pathExtension == "app" else { return }
                    Task { @MainActor in model.addToGroup(url.path, item.id) }
                }
            }
            return true
        }
    }
}

struct GroupAppTile: View {
    let path: String
    let groupID: String
    @ObservedObject var model: DockModel
    let showBadge: Bool
    @State private var hovering = false

    private var name: String {
        FileManager.default.displayName(atPath: path).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        let running = model.isRunning(path)
        VStack(spacing: 3) {
            Image(nsImage: model.icon(for: path))
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)
                .overlay(alignment: .topTrailing) {
                    if showBadge, let text = model.badges[path] {
                        Text(text)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(Capsule().fill(Color.red))
                            .offset(x: 4, y: -4)
                    }
                }
            Text(name).font(.system(size: 11)).lineLimit(1).frame(width: 80)
            Circle().fill(Color.primary.opacity(0.7)).frame(width: 4, height: 4).opacity(running ? 1 : 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.openApp(path) }
        .contextMenu {
            Button("Open") { model.openApp(path) }
            Button("Remove from Group") { model.removeFromGroup(path, groupID) }
            Button("Show in Finder") { model.showInFinder(URL(fileURLWithPath: path)) }
            if running {
                Divider()
                Button("Quit") {
                    NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == path }.forEach { $0.terminate() }
                }
            }
        }
    }
}


struct StackView: View {
    let root: URL
    @ObservedObject var model: DockModel
    @ObservedObject var prefs: Prefs
    @State private var path: [URL] = []
    @State private var entries: [StackEntry]

    init(root: URL, model: DockModel, prefs: Prefs) {
        self.root = root
        self.model = model
        self.prefs = prefs
        _entries = State(initialValue: model.contents(of: root, sort: model.sort(for: root.path)))
    }

    private var current: URL { path.last ?? root }
    private var columns: Int { Int(prefs.stackColumns) }
    private let tile: CGFloat = 84

    private func reload() {
        entries = model.contents(of: current, sort: model.sort(for: root.path))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if !path.isEmpty {
                    Button { path.removeLast() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless)
                }
                Text(FileManager.default.displayName(atPath: current.path)).font(.headline)
                Spacer()
                Text("\(entries.count) items").font(.caption).foregroundStyle(.secondary)
            }
            .padding(12)
            Divider()
            if entries.isEmpty {
                Text("Empty folder").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
            } else {
                let rows = (entries.count + columns - 1) / columns
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(tile), spacing: 8), count: columns), spacing: 10) {
                        ForEach(entries) { entry in
                            StackTile(entry: entry) { open(entry) }
                        }
                    }
                    .padding(12)
                }
                .frame(height: min(CGFloat(rows) * 106 + 24, 440))
            }
            Divider()
            HStack {
                Button("Open in Finder") {
                    model.openInFinder(current)
                    model.openStack = nil
                }
                .buttonStyle(.borderless)
                Spacer()
            }
            .padding(10)
        }
        .frame(width: CGFloat(columns) * tile + CGFloat(columns - 1) * 8 + 24)
        .onChange(of: path) { _, _ in reload() }
        .onChange(of: model.prefsVersion) { _, _ in reload() }
    }

    private func open(_ entry: StackEntry) {
        if entry.isFolder {
            path.append(entry.url)
        } else {
            NSWorkspace.shared.open(entry.url)
            model.openStack = nil
        }
    }
}

struct StackTile: View {
    let entry: StackEntry
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            FileIcon(url: entry.url, size: 52)
            Text(entry.name)
                .font(.system(size: 11))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 80)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color.primary.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open", action: action)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
        }
    }
}

/// File icon that upgrades to a Quick Look thumbnail (images, PDFs, videos) when one exists.
/// Icons and thumbnails are kept in memory so redraws never hit the disk.
@MainActor
enum IconCache {
    static let icons = NSCache<NSString, NSImage>()
    static let thumbnails = NSCache<NSString, NSImage>()

    static func icon(_ path: String) -> NSImage {
        if let cached = icons.object(forKey: path as NSString) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons.setObject(image, forKey: path as NSString)
        return image
    }
}

struct FileIcon: View {
    let url: URL
    let size: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? IconCache.thumbnails.object(forKey: url.path as NSString) ?? IconCache.icon(url.path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: url) {
                let key = url.path as NSString
                if let cached = IconCache.thumbnails.object(forKey: key) { thumbnail = cached; return }
                let request = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: 96, height: 96),
                    scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
                if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                    IconCache.thumbnails.setObject(rep.nsImage, forKey: key)
                    thumbnail = rep.nsImage
                }
            }
    }
}
