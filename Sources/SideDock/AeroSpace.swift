import Foundation

/// Reads which AeroSpace workspace each app's windows are on, via the `aerospace` CLI (~30 ms).
enum AeroSpace {
    static let binary: String? = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Snapshot: Equatable {
        var workspaces: [String: [String]] = [:]   // app bundle path -> workspaces, in order
        var focused: String?
    }

    static func read() -> Snapshot? {
        guard let out = run(["list-windows", "--all", "--format", "%{app-bundle-path}|%{workspace}|%{workspace-is-focused}"])
        else { return nil }
        var snap = Snapshot()
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, !parts[0].isEmpty else { continue }
            if !snap.workspaces[parts[0], default: []].contains(parts[1]) {
                snap.workspaces[parts[0], default: []].append(parts[1])
            }
            if parts[2] == "true" { snap.focused = parts[1] }
        }
        if snap.focused == nil { snap.focused = run(["list-workspaces", "--focused"])?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return snap
    }

    static func focus(_ workspace: String) {
        DispatchQueue.global(qos: .userInitiated).async { _ = run(["workspace", workspace]) }
    }

    private static func run(_ args: [String]) -> String? {
        guard let binary else { return nil }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return task.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
