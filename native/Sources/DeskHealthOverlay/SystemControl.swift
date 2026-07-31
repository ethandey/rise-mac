import Foundation

/// App data root + optional legacy Python CLI helpers.
enum SystemControl {
    /// Writable install root for config, logs, and state.
    /// - Dev / repo: repo folder containing `bin/` and `data/`
    /// - Distributed Rise.app in Applications (or elsewhere):
    ///   `~/Library/Application Support/Rise`
    static var root: String {
        if let appSupport = applicationSupportRootIfBundled() {
            return appSupport
        }
        return legacyRepoRoot()
    }

    /// When running as Rise.app outside the repo, use Application Support.
    private static func applicationSupportRootIfBundled() -> String? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let dir = exe.deletingLastPathComponent()
        guard dir.lastPathComponent == "MacOS" else { return nil }
        // …/Something.app/Contents/MacOS
        let contents = dir.deletingLastPathComponent()
        let appBundle = contents.deletingLastPathComponent()
        guard appBundle.pathExtension == "app" else { return nil }

        // Still living under repo/bin/Rise.app → use repo root for data
        let parent = appBundle.deletingLastPathComponent()
        if parent.lastPathComponent == "bin" {
            let repo = parent.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: repo.appendingPathComponent("data").path)
                || FileManager.default.fileExists(atPath: repo.appendingPathComponent("native").path) {
                return repo.path
            }
        }

        // Distributed app — Application Support
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = home
            .appendingPathComponent("Library/Application Support/Rise", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let data = support.appendingPathComponent("data", isDirectory: true)
        try? FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        // Seed default config once
        let cfg = data.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: cfg.path) {
            if let bundled = Bundle.main.url(forResource: "config.default", withExtension: "json"),
               let bytes = try? Data(contentsOf: bundled) {
                try? bytes.write(to: cfg)
            } else {
                let defaultJSON = """
                {
                  "enabled": true,
                  "workday_start": "07:00",
                  "workday_end": "20:00",
                  "quiet_lunch": false,
                  "has_standing_desk": true,
                  "intervals": { "A": 25, "B": 40, "C": 90, "S": 30 }
                }
                """
                try? defaultJSON.data(using: .utf8)?.write(to: cfg)
            }
        }
        return support.path
    }

    private static func legacyRepoRoot() -> String {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var dir = exe.deletingLastPathComponent()

        if dir.lastPathComponent == "MacOS" {
            dir = dir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            if dir.lastPathComponent == "bin" {
                return dir.deletingLastPathComponent().path
            }
            return dir.path
        }
        if dir.lastPathComponent == "bin" {
            return dir.deletingLastPathComponent().path
        }
        if dir.lastPathComponent == "release" {
            return dir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
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
