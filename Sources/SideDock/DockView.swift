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
        .onDrop(of: [.fileURL, .sideDockItem], delegate: ItemDrop(target: nil, model: model))
    }
}

// MARK: - Icon

struct DockIcon: View {
    let item: DockItem
    @ObservedObject var model: DockModel
    @ObservedObject var prefs: Prefs
    @State private var hovering = false

    private var size: CGFloat { prefs.iconSize }

    private var stackOpen: Binding<Bool> {
        Binding(get: { model.openStack == item.id },
                set: { if !$0, model.openStack == item.id { model.openStack = nil } })
    }

    var body: some View {
        HStack(spacing: 3) {
            if prefs.edge == .left { dot }
            iconImage
                .frame(width: size, height: size)
                .overlay(alignment: .topTrailing) { badge }
                .scaleEffect(hovering && prefs.magnify ? prefs.magnifyAmount : 1,
                             anchor: prefs.edge == .left ? .leading : .trailing)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
            if prefs.edge == .right { dot }
        }
        .zIndex(hovering ? 1 : 0)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
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
        .onDrop(of: [.fileURL, .sideDockItem], delegate: ItemDrop(target: item, model: model))
        .help(prefs.showTooltips ? item.name : "")
        .popover(isPresented: stackOpen, arrowEdge: prefs.edge == .left ? .trailing : .leading) {
            StackView(root: item.url, model: model, prefs: prefs)
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
        if item.kind == .folder, model.display(for: item.id) == .stack,
           let entries = model.folderPreviews[item.id], !entries.isEmpty {
            StackPreview(entries: entries, size: size)
        } else {
            Image(nsImage: model.icon(for: item.id)).resizable().interpolation(.high)
        }
    }

    @ViewBuilder private var badge: some View {
        if prefs.showBadges, let text = model.badges[item.id] {
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
        if item.isPinned {
            Button("Remove from Dock") { model.unpin(item) }
        } else {
            Button("Keep in Dock") { model.pin(item.id) }
        }
        Button("Show in Finder") { model.showInFinder(item.url) }
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

// MARK: - Drag and drop

/// Reorders icons dragged inside the dock, and pins apps, folders or files dropped from Finder.
struct ItemDrop: DropDelegate {
    let target: DockItem?   // nil = empty area (append to the end)
    let model: DockModel

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.sideDockItem, .fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard info.hasItemsConforming(to: [.sideDockItem]),
              let dragged = model.dragging, let target, target.isPinned, dragged != target.id else { return }
        withAnimation(.easeInOut(duration: 0.15)) { model.pin(dragged, before: target.id) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: info.hasItemsConforming(to: [.sideDockItem]) ? .move : .copy)
    }

    func performDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.sideDockItem]) {
            if let dragged = model.dragging, target?.isPinned != true, !model.pinnedPaths.contains(dragged) {
                model.pin(dragged)   // a running app dragged into the dock gets kept
            }
            model.dragging = nil
            return true
        }
        let before = target?.isPinned == true ? target?.id : nil
        for provider in info.itemProviders(for: [.fileURL]) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.pin(url.path, before: before) }
            }
        }
        return true
    }
}

// MARK: - Folder stacks

/// 2x2 grid of a folder's newest items, like the macOS Dock's stack icon.
struct StackPreview: View {
    let entries: [StackEntry]
    let size: CGFloat

    var body: some View {
        let cell = (size - 10) / 2
        RoundedRectangle(cornerRadius: size * 0.22)
            .fill(Color.primary.opacity(0.12))
            .overlay {
                LazyVGrid(columns: [GridItem(.fixed(cell), spacing: 3), GridItem(.fixed(cell), spacing: 3)], spacing: 3) {
                    ForEach(entries) { FileIcon(url: $0.url, size: cell) }
                }
            }
    }
}

struct StackView: View {
    let root: URL
    @ObservedObject var model: DockModel
    @ObservedObject var prefs: Prefs
    @State private var path: [URL] = []

    private var current: URL { path.last ?? root }
    private var columns: Int { Int(prefs.stackColumns) }
    private let tile: CGFloat = 84

    var body: some View {
        let entries = model.contents(of: current, sort: model.sort(for: root.path))
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
struct FileIcon: View {
    let url: URL
    let size: CGFloat
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .task(id: url) {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url, size: CGSize(width: size, height: size),
                    scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
                if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                    thumbnail = rep.nsImage
                }
            }
    }
}
