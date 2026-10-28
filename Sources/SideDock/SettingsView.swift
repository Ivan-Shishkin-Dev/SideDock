import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: DockModel
    @ObservedObject var prefs: Prefs

    var body: some View {
        TabView {
            GeneralTab(prefs: prefs).tabItem { Label("General", systemImage: "gearshape") }
            AppearanceTab(prefs: prefs).tabItem { Label("Appearance", systemImage: "paintbrush") }
            BehaviorTab(prefs: prefs).tabItem { Label("Behavior", systemImage: "cursorarrow.motionlines") }
            ItemsTab(model: model).tabItem { Label("Items", systemImage: "square.grid.2x2") }
            FoldersTab(prefs: prefs).tabItem { Label("Folders", systemImage: "folder") }
            BadgesTab(prefs: prefs).tabItem { Label("Badges", systemImage: "app.badge") }
            AboutTab(prefs: prefs).tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 560, height: 500)
    }
}

/// Slider row with the current value shown on the right.
private struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var format: (Double) -> String = { "\(Int($0))" }

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range, step: step)
                Text(format(value)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
        }
    }
}

private let seconds: (Double) -> String = { String(format: "%.2fs", $0) }

// MARK: - Tabs

private struct GeneralTab: View {
    @ObservedObject var prefs: Prefs
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section("Placement") {
                Picker("Screen edge", selection: $prefs.edge) {
                    ForEach(DockEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Position on edge", selection: $prefs.position) {
                    ForEach(DockPosition.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                Toggle("Show menu bar icon", isOn: $prefs.showMenuBarIcon)
                if !prefs.showMenuBarIcon {
                    Text("⌘-click the dock to get back to Settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Apps") {
                Toggle("Show running apps that aren't kept in the dock", isOn: $prefs.showRunningApps)
                Toggle("Clicking the frontmost app hides it", isOn: $prefs.clickActiveToHide)
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription). Move SideDock.app to /Applications and try again."
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct AppearanceTab: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Form {
            Section("Icons") {
                ValueSlider(title: "Icon size", value: $prefs.iconSize, range: 24...96, format: { "\(Int($0)) pt" })
                ValueSlider(title: "Spacing", value: $prefs.spacing, range: 0...24, format: { "\(Int($0)) pt" })
                Toggle("Magnify on hover", isOn: $prefs.magnify)
                if prefs.magnify {
                    ValueSlider(title: "Magnification", value: $prefs.magnifyAmount, range: 1.05...1.8, step: 0.05,
                                format: { "\(Int(($0 * 100).rounded()))%" })
                }
                Toggle("Show running indicators", isOn: $prefs.showIndicators)
                Toggle("Show names on hover", isOn: $prefs.showTooltips)
            }
            Section("Background") {
                Picker("Style", selection: $prefs.material) {
                    ForEach(DockMaterial.allCases) { Text($0.title).tag($0) }
                }
                ValueSlider(title: "Corner radius", value: $prefs.cornerRadius, range: 0...32, format: { "\(Int($0)) pt" })
                ValueSlider(title: "Gap from edge", value: $prefs.edgeGap, range: 0...40, format: { "\(Int($0)) pt" })
            }
        }
        .formStyle(.grouped)
    }
}

private struct BehaviorTab: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Form {
            Section("Auto-hide") {
                Toggle("Hide the dock until the pointer touches the screen edge", isOn: $prefs.autoHide)
                if prefs.autoHide {
                    ValueSlider(title: "Show after", value: $prefs.revealDelay, range: 0...1, step: 0.05, format: seconds)
                    ValueSlider(title: "Hide after", value: $prefs.hideDelay, range: 0...2, step: 0.05, format: seconds)
                }
            }
            Section("Animation") {
                ValueSlider(title: "Slide speed", value: $prefs.animationDuration, range: 0...0.6, step: 0.02, format: seconds)
            }
            Section("Shortcuts") {
                LabeledContent("Open Settings", value: "⌘-click the dock")
                LabeledContent("Reorder icons", value: "Drag them")
                LabeledContent("Keep an app, folder or file", value: "Drop it on the dock")
            }
        }
        .formStyle(.grouped)
    }
}

private struct ItemsTab: View {
    @ObservedObject var model: DockModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Items kept in the dock. Drag rows to reorder.").foregroundStyle(.secondary)
            List {
                ForEach(model.pinnedItems) { item in
                    HStack {
                        if item.kind == .group {
                            StackPreview(urls: item.members.prefix(4).map { URL(fileURLWithPath: $0) }, size: 22)
                        } else {
                            Image(nsImage: model.icon(for: item.id)).resizable().frame(width: 22, height: 22)
                        }
                        VStack(alignment: .leading) {
                            Text(item.name)
                            Text(item.kind == .group ? "Group: " + item.members.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }.joined(separator: ", ") : item.id)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button { model.unpin(item) } label: { Image(systemName: "minus.circle.fill").foregroundStyle(.red) }
                            .buttonStyle(.borderless)
                            .help("Remove from dock")
                    }
                }
                .onMove { model.move(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            HStack {
                Button("Add App…") { choose(folders: false) }
                Button("Add Folder…") { choose(folders: true) }
                Button("New Group…") { chooseGroup() }
                Menu("Add Shortcut") {
                    Button("Home") { model.pin(NSHomeDirectory()) }
                    Button("Downloads") { model.pin(NSHomeDirectory() + "/Downloads") }
                    Button("Documents") { model.pin(NSHomeDirectory() + "/Documents") }
                    Button("Desktop") { model.pin(NSHomeDirectory() + "/Desktop") }
                    Button("Applications") { model.pin("/Applications") }
                }
                .fixedSize()
                Spacer()
                Button("Reset to Defaults") { model.pinnedPaths = DockModel.defaultPins }
            }
        }
        .padding(20)
    }

    /// Pick several apps to put into a new group.
    private func chooseGroup() {
        let panel = NSOpenPanel()
        panel.message = "Choose the apps for the new group (⌘-click to pick several)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            let id = model.createGroup(with: panel.urls.map(\.path))
            model.promptRename(id)
        }
    }

    private func choose(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        if !folders {
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            panel.allowedContentTypes = [.application]
        }
        if panel.runModal() == .OK {
            panel.urls.forEach { model.pin($0.path) }
        }
    }
}

private struct FoldersTab: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        Form {
            Section {
                Picker("Sort by", selection: $prefs.defaultSort) {
                    Text("Name").tag(StackSort.name)
                    Text("Date Added").tag(StackSort.dateAdded)
                }
                Picker("Display as", selection: $prefs.defaultDisplay) {
                    Text("Folder icon").tag(StackDisplay.folder)
                    Text("Stack of contents").tag(StackDisplay.stack)
                }
                ValueSlider(title: "Grid columns", value: $prefs.stackColumns, range: 3...7)
            } header: {
                Text("Defaults for folders")
            } footer: {
                Text("Right-click a folder in the dock to override these for that folder. Downloads sorts by Date Added unless you change it.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct BadgesTab: View {
    @ObservedObject var prefs: Prefs
    @State private var trusted = DockBadges.isTrusted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Show notification badges", isOn: $prefs.showBadges)
                    .onChange(of: prefs.showBadges) { _, on in if on && !trusted { DockBadges.requestAccess() } }
                LabeledContent("Accessibility access") {
                    Label(trusted ? "Granted" : "Not granted",
                          systemImage: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(trusted ? .green : .orange)
                }
                if !trusted {
                    Button("Open Accessibility Settings") { DockBadges.openAccessibilitySettings() }
                }
            } footer: {
                Text("macOS doesn't share other apps' badges, so SideDock reads them from the system Dock. That needs Accessibility access. If you rebuild SideDock, macOS may ask again.")
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in trusted = DockBadges.isTrusted }
    }
}

private struct AboutTab: View {
    @ObservedObject var prefs: Prefs

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "dock.rectangle").font(.system(size: 48)).foregroundStyle(.tint)
            Text("SideDock").font(.title.bold())
            Text("A second dock for your Mac's screen edge.").foregroundStyle(.secondary)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.caption).foregroundStyle(.secondary)
            Spacer().frame(height: 12)
            HStack {
                Button("Reset All Settings") { prefs.resetAll() }
                Button("Quit SideDock") { NSApp.terminate(nil) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
