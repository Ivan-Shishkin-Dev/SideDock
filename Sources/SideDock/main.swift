import AppKit
import Combine
import QuartzCore
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
    // Let the panel park just past the screen edge while hidden.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
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

    /// Slide in progress, driven by the display's refresh rate.
    private struct Slide { var from: NSPoint; var to: NSPoint; var fromAlpha: CGFloat; var toAlpha: CGFloat; var start: CFTimeInterval; var duration: Double }
    private var slide: Slide?
    private var displayLink: CADisplayLink?

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
        // Content changes (apps launching, badges) only resize; they never restart the slide.
        model.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateSize() }
            .store(in: &cancellables)

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateSize() }
        }
        NotificationCenter.default.addObserver(forName: .openSideDockSettings, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettings() }
        }

        panel.orderFrontRegardless()
        // React to the pointer the moment it moves, not on a polling interval.
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.trackMouse() }
            return event
        }
        // Fallback for delays and for when the pointer stops moving.
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.slowTick() }
        }
        slowTick()

        // AeroSpace workspace numbers: poll fast, and right away when apps switch.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAero() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAero() }
        }
        refreshAero()

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
        updateSize()
    }

    private var aeroBusy = false

    private func refreshAero() {
        guard prefs.showWorkspaces, AeroSpace.binary != nil, !aeroBusy else { return }
        aeroBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = AeroSpace.read()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.aeroBusy = false
                    if let snap { self.model.setAero(snap) }
                }
            }
        }
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

    private var visible: Bool { isShown || !prefs.autoHide }

    /// Fits the window to the dock's content without animating its position.
    private func updateSize() {
        guard hosting != nil else { return }
        let target = frame(shown: visible)
        if hosting.frame.size != target.size {
            hosting.frame = NSRect(origin: .zero, size: target.size)
        }
        if slide != nil {
            // Mid-slide: resize now and steer the slide to the new end point.
            if panel.frame.size != target.size {
                panel.setFrame(NSRect(origin: panel.frame.origin, size: target.size), display: true)
            }
            slide?.to = target.origin
        } else if panel.frame != target {
            panel.setFrame(target, display: true)
            panel.alphaValue = visible ? 1 : 0
        }
    }

    private func setShown(_ shown: Bool, animated: Bool) {
        guard shown != isShown else { return }
        isShown = shown
        if !shown { model.hoveredID = nil }
        let target = frame(shown: visible)
        hosting.frame = NSRect(origin: .zero, size: target.size)
        if panel.frame.size != target.size {
            panel.setFrame(NSRect(origin: panel.frame.origin, size: target.size), display: true)
        }
        let alpha: CGFloat = visible ? 1 : 0
        guard animated, prefs.animationDuration > 0 else {
            slide = nil
            panel.setFrameOrigin(target.origin)
            panel.alphaValue = alpha
            return
        }
        // Moving only the window origin is cheap: nothing inside has to redraw.
        slide = Slide(from: panel.frame.origin, to: target.origin, fromAlpha: panel.alphaValue, toAlpha: alpha,
                      start: CACurrentMediaTime(), duration: prefs.animationDuration)
        // Fresh display link every slide: a link tied to a screen that was unplugged or rearranged
        // stops firing, which used to freeze the dock in place. (A view's link also stops offscreen.)
        displayLink?.invalidate()
        let link = (panel.screen ?? screen).displayLink(target: self, selector: #selector(stepSlide(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Safety net, run from the 0.1 s timer: if a slide outlived its duration (its display link
    /// died), jump straight to where it was going.
    private func finishStuckSlide() {
        guard let s = slide, CACurrentMediaTime() - s.start > s.duration + 0.25 else { return }
        panel.setFrameOrigin(s.to)
        panel.alphaValue = s.toAlpha
        slide = nil
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func stepSlide(_ link: CADisplayLink) {
        guard let s = slide else {
            displayLink?.invalidate()
            displayLink = nil
            return
        }
        let t = min(1, (CACurrentMediaTime() - s.start) / s.duration)
        let eased = 1 - pow(1 - t, 3)   // ease-out: fast start, gentle stop
        panel.setFrameOrigin(NSPoint(x: s.from.x + (s.to.x - s.from.x) * eased,
                                     y: s.from.y + (s.to.y - s.from.y) * eased))
        panel.alphaValue = s.fromAlpha + (s.toAlpha - s.fromAlpha) * CGFloat(min(1, t * 1.6))
        if t >= 1 {
            slide = nil
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    /// Reveal when the pointer touches the screen edge; hide shortly after it leaves.
    private var dragBaseline = NSPasteboard(name: .drag).changeCount

    /// Notices drags anywhere (Finder files, dock icons) so the Trash can appear while you hold something.
    private func trackDrag() {
        let down = NSEvent.pressedMouseButtons & 1 != 0
        let count = NSPasteboard(name: .drag).changeCount
        if !down { dragBaseline = count }
        let holding = down && (count != dragBaseline || model.dragging != nil)
        if holding != model.holdingDrag { model.holdingDrag = holding }
    }

    private func trackMouse() {
        trackDrag()
        finishStuckSlide()
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
            // Stay open while the pointer is over the dock or an open folder/group popup.
            let popups = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
            let near = panel.frame.insetBy(dx: -24, dy: -24).contains(p)
                || popups.contains { $0.frame.insetBy(dx: -24, dy: -24).contains(p) }
            // A drag that ended outside the dock never reaches a drop handler, so clear it
            // once the mouse button is up; otherwise the dock would stay open forever.
            if model.dragging != nil && NSEvent.pressedMouseButtons & 1 == 0 { model.dragging = nil }
            if near || model.dragging != nil {
                mouseLeftAt = nil
            } else if let left = mouseLeftAt {
                if Date().timeIntervalSince(left) > prefs.hideDelay {
                    model.openStack = nil
                    setShown(false, animated: true)
                }
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
    @objc private func restartAction() { restartSideDock() }
}

/// Quits and relaunches SideDock: a quick fix when the dock gets into a bad state.
@MainActor func restartSideDock() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/sh")
    task.arguments = ["-c", "sleep 0.6; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
    try? task.run()
    NSApp.terminate(nil)
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
        add("Restart SideDock", #selector(restartAction), key: "r")
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
