import Foundation

/// Thin bridge to optional Python CLI helpers (pause/resume/snooze).
enum SystemControl {
    /// Install root: …/bin/DeskHealthOverlay → parent of bin
    static var root: String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // …/bin/DeskHealthOverlay or …/.build/release/DeskHealthOverlay
        let dir = exe.deletingLastPathComponent()
        if dir.lastPathComponent == "bin" {
            return dir.deletingLastPathComponent().path
        }
        // Dev build: native/.build/release → repo root two levels up from .build
        if dir.lastPathComponent == "release" {
            return dir
                .deletingLastPathComponent() // .build
                .deletingLastPathComponent() // native
                .deletingLastPathComponent() // root
                .path
        }
        return dir.path
    }

    static var ctl: String { root + "/bin/desk-health" }
    static var daemon: String { root + "/bin/desk_health.py" }

    @discardableResult
    static func run(_ args: String...) -> Bool {
        let task = Process()
        if FileManager.default.isExecutableFile(atPath: ctl) {
            task.executableURL = URL(fileURLWithPath: ctl)
            task.arguments = args
        } else if FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            task.arguments = [daemon] + args
        } else {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["python3", daemon] + args
        }
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
