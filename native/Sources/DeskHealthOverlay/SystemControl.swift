import Foundation

/// Thin bridge to optional Python CLI helpers (pause/resume/snooze).
enum SystemControl {
    /// Install root: repo folder containing `bin/` and `data/`.
    static var root: String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()

        // Rise.app/Contents/MacOS/Rise → …/bin/Rise.app/… → repo root
        if dir.lastPathComponent == "MacOS" {
            // MacOS → Contents → Rise.app → bin → root
            dir = dir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if dir.lastPathComponent == "bin" {
                return dir.deletingLastPathComponent().path
            }
            return dir.path
        }

        // …/bin/DeskHealthOverlay
        if dir.lastPathComponent == "bin" {
            return dir.deletingLastPathComponent().path
        }
        // Dev build: native/.build/release
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
