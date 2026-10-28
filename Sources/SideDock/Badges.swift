import AppKit
import ApplicationServices

/// Reads notification badges (the red "1" bubbles) from the system Dock via Accessibility.
/// macOS has no public API for other apps' badges, so this needs Accessibility permission.
enum DockBadges {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Returns badge text keyed by app path, e.g. ["/Applications/Notion.app": "1"].
    static func read() -> [String: String] {
        guard isTrusted,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return [:] }
        let root = AXUIElementCreateApplication(dock.processIdentifier)
        var result: [String: String] = [:]
        for list in children(of: root) {
            for item in children(of: list) {
                guard let label = value(item, "AXStatusLabel") as? String, !label.isEmpty,
                      let url = value(item, kAXURLAttribute) as? URL else { continue }
                result[url.standardizedFileURL.path] = label
            }
        }
        return result
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        value(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var out: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &out)
        return out
    }
}
