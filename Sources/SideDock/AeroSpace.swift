import Foundation

/// Reads which AeroSpace workspace each app's windows are on, via the `aerospace` CLI (~30 ms).
enum AeroSpace {
    static let binary: String? = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    struct Snapshot: Equatable {
        var workspaces: [String: [String]] = [:]   // app bundle path -> workspaces, in order
        var apps: [String: [String]] = [:]         // workspace -> app bundle paths, in order
        var all: [String] = []                     // every workspace AeroSpace knows
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
            if !snap.apps[parts[1], default: []].contains(parts[0]) {
                snap.apps[parts[1], default: []].append(parts[0])
            }
            if parts[2] == "true" { snap.focused = parts[1] }
        }
        snap.all = run(["list-workspaces", "--all"])?.split(separator: "\n").map(String.init) ?? []
        if snap.focused == nil { snap.focused = run(["list-workspaces", "--focused"])?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return snap
    }

    /// Workspaces laid out like the keyboard: 1 2 3 / Q W E / A S D / Z X C.
    /// Returns rows of cells; nil marks a key with no workspace (a blank spot that keeps the shape).
    static func keyboardRows(_ all: [String]) -> [[String?]] {
        let keys = ["1234567890", "QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"].map { $0.map(String.init) }
        let have = Set(all.map { $0.uppercased() })
        let byUpper = Dictionary(all.map { ($0.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let width = keys.compactMap { row in row.lastIndex(where: have.contains).map { $0 + 1 } }.max() ?? 0
        var rows = keys.filter { $0.prefix(width).contains(where: have.contains) }
            .map { $0.prefix(width).map { byUpper[$0] } }
        // Named workspaces that aren't single keys go on extra rows.
        let others = all.filter { !keys.joined().contains($0.uppercased()) }
        let cols = max(width, 1)
        for start in stride(from: 0, to: others.count, by: cols) {
            let chunk = others[start..<min(start + cols, others.count)].map { Optional($0) }
            rows.append(chunk + Array(repeating: nil, count: cols - chunk.count))
        }
        return rows
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
