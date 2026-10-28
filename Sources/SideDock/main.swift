import AppKit
import Combine
import SwiftUI

/// Borderless floating panel that never steals focus from the app you're using.
final class DockPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the dock. Clicks work on the first try, and ⌘-click anywhere opens Settings.
final class DockHostingView<V: View>: NSHostingView<V> {
    var onCommandClick: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let onCommandClick {
            onCommandClick()
        } else {
            super.mouseDown(with: event)
        }
    }
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let model = DockModel()
    private let prefs = Prefs.shared
    private let panel = DockPanel()
    private let blur = NSVisualEffectView()
    private var hosting: DockHostingView<DockView>!
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    private var isShown = true
    private var mouseLeftAt: Date?
    private var edgeHitAt: Date?

    func applicationDidFinishLaunching(_ note: Notification) {
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.masksToBounds = true
        panel.contentView = blur

        hosting = DockHostingView(rootView: DockView(model: model, prefs: prefs))
        hosting.onCommandClick = { [weak self] in self?.openSettings() }
        blur.addSubview(hosting)

        applyPrefs()
        prefs.objectWillChange
            .receive(on: RunLoop.main)   // runs after the new value is stored
            .sink { [weak self] _ in self?.applyPrefs() }
            .store(in: &cancellables)
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout(animated: true) }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(animated: false) }
        }
        NotificationCenter.default.addObserver(forName: .openSideDockSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        panel.orderFrontRegardless()
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.slowTick() }
        }
        slowTick()

        // Start hidden after a moment so you can see where it lives.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.prefs.autoHide else { return }
            self.setShown(false, animated: true)
        }
    }

    /// Applies settings that live outside SwiftUI (window look, menu bar icon, position).
    private func applyPrefs() {
        blur.material = prefs.material.ns
        blur.layer?.cornerRadius = prefs.cornerRadius
        if prefs.showMenuBarIcon && statusItem == nil {
            setupStatusItem()
        } else if !prefs.showMenuBarIcon, let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        if !prefs.autoHide { isShown = true }
        model.reloadFolderPreviews()
        layout(animated: true)
    }

    /// Refreshes folder stacks and badges every couple of seconds.
    private func slowTick() {
        model.reloadFolderPreviews()
        guard prefs.showBadges else { model.setBadges([:]); return }
        DispatchQueue.global(qos: .utility).async {
            let badges = DockBadges.read()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.model.setBadges(badges) } }
        }
    }

    // MARK: Positioning

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    private func frame(shown: Bool) -> NSRect {
        let size = hosting.fittingSize
        let area = screen.visibleFrame
        let height = min(size.height, area.height)
        let y: CGFloat
        switch prefs.position {
        case .top: y = area.maxY - height - 8
        case .center: y = area.midY - height / 2
        case .bottom: y = area.minY + 8
        }
        let x: CGFloat
        switch prefs.edge {
        case .left:  x = shown ? area.minX + prefs.edgeGap : screen.frame.minX - size.width - 1
        case .right: x = shown ? area.maxX - size.width - prefs.edgeGap : screen.frame.maxX + 1
        }
        return NSRect(x: x, y: max(area.minY, y), width: size.width, height: height)
    }

    private func layout(animated: Bool) {
        guard hosting != nil else { return }
        let target = frame(shown: isShown || !prefs.autoHide)
        hosting.frame = NSRect(origin: .zero, size: target.size)
        guard target != panel.frame else { return }
        if animated && prefs.animationDuration > 0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = prefs.animationDuration
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    private func setShown(_ shown: Bool, animated: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        layout(animated: animated)
    }

    /// Reveal when the pointer touches the screen edge; hide shortly after it leaves.
    private func trackMouse() {
        guard prefs.autoHide else { return }
        let p = NSEvent.mouseLocation
        let full = screen.frame
        let area = screen.visibleFrame
        if !isShown {
            let atEdge = prefs.edge == .left ? p.x <= full.minX + 1 : p.x >= full.maxX - 2
            guard atEdge && p.y >= area.minY && p.y <= area.maxY else { edgeHitAt = nil; return }
            let since = edgeHitAt ?? Date()
            edgeHitAt = since
            if Date().timeIntervalSince(since) >= prefs.revealDelay {
                setShown(true, animated: true)
                mouseLeftAt = nil
                edgeHitAt = nil
            }
        } else {
            // Stay open while a folder stack or the Settings window is in use.
            if model.openStack != nil || model.dragging != nil
                || panel.frame.insetBy(dx: -24, dy: -24).contains(p) {
                mouseLeftAt = nil
            } else if let left = mouseLeftAt {
                if Date().timeIntervalSince(left) > prefs.hideDelay { setShown(false, animated: true) }
            } else {
                mouseLeftAt = Date()
            }
        }
    }

    // MARK: Settings window

    func openSettings() {
        model.openStack = nil
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, prefs: prefs)))
            window.title = "SideDock Settings"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "dock.rectangle", accessibilityDescription: "SideDock")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    @objc private func setLeft() { prefs.edge = .left }
    @objc private func setRight() { prefs.edge = .right }
    @objc private func toggleAutoHide() { prefs.autoHide.toggle() }
    @objc private func settingsAction() { openSettings() }
}

extension AppController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, on: Bool = false, key: String = "") {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add("Settings…", #selector(settingsAction), key: ",")
        menu.addItem(.separator())
        add("Left Edge", #selector(setLeft), on: prefs.edge == .left)
        add("Right Edge", #selector(setRight), on: prefs.edge == .right)
        add("Auto-hide", #selector(toggleAutoHide), on: prefs.autoHide)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit SideDock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.accessory)
    app.run()
}
