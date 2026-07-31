import AppKit
import Foundation

/// Checks GitHub for newer Rise releases (and tags if no formal release yet).
@MainActor
enum UpdateChecker {
    static let repoSlug = "ethandey/rise-mac"
    static let releasesPage = URL(string: "https://github.com/ethandey/rise-mac/releases")!
    static let repoPage = URL(string: "https://github.com/ethandey/rise-mac")!
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/ethandey/rise-mac/releases/latest")!
    static let tagsAPI = URL(string: "https://api.github.com/repos/ethandey/rise-mac/tags?per_page=5")!

    enum CheckResult {
        case upToDate(current: String, latest: String)
        case updateAvailable(current: String, latest: String, htmlURL: URL?)
        case noPublishedVersion(current: String)
        case failed(current: String, message: String)
    }

    static var currentVersion: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return "0.0.0"
    }

    static var currentBuild: String {
        if let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !b.isEmpty {
            return b
        }
        return "—"
    }

    /// Hit GitHub Releases, then tags, compare to this build’s short version.
    static func checkLatest() async -> CheckResult {
        let current = currentVersion

        do {
            if let release = try await fetchLatestRelease() {
                let latest = normalizeTag(release.tag)
                if isVersion(current, lessThan: latest) {
                    return .updateAvailable(current: current, latest: latest, htmlURL: release.htmlURL)
                }
                return .upToDate(current: current, latest: latest)
            }

            if let tag = try await fetchLatestTag() {
                let latest = normalizeTag(tag)
                if isVersion(current, lessThan: latest) {
                    return .updateAvailable(
                        current: current,
                        latest: latest,
                        htmlURL: URL(string: "https://github.com/\(repoSlug)/releases/tag/\(tag)")
                    )
                }
                return .upToDate(current: current, latest: latest)
            }

            return .noPublishedVersion(current: current)
        } catch {
            return .failed(current: current, message: error.localizedDescription)
        }
    }

    // MARK: - Network

    private struct ReleaseInfo {
        var tag: String
        var htmlURL: URL?
    }

    private static func fetchLatestRelease() async throws -> ReleaseInfo? {
        var request = URLRequest(url: latestReleaseAPI)
        request.setValue("Rise/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        // 404 = no releases published yet
        if http.statusCode == 404 { return nil }
        guard (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Draft/prerelease: still surface tag if present
        guard let tag = json["tag_name"] as? String, !tag.isEmpty else { return nil }
        let html = (json["html_url"] as? String).flatMap { URL(string: $0) }
        return ReleaseInfo(tag: tag, htmlURL: html)
    }

    private static func fetchLatestTag() async throws -> String? {
        var request = URLRequest(url: tagsAPI)
        request.setValue("Rise/\(currentVersion) (macOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        // Prefer tags that look like versions
        for item in arr {
            guard let name = item["name"] as? String, !name.isEmpty else { continue }
            let norm = normalizeTag(name)
            if norm.split(separator: ".").compactMap({ Int($0) }).count >= 2 {
                return name
            }
        }
        return arr.first?["name"] as? String
    }

    // MARK: - Semver helpers

    static func normalizeTag(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s = String(s.dropFirst())
        }
        // strip pre-release suffix for comparison base: 1.2.0-beta → 1.2.0
        if let dash = s.firstIndex(of: "-") {
            s = String(s[..<dash])
        }
        return s
    }

    /// True if `a` is strictly older than `b` (missing parts treated as 0).
    static func isVersion(_ a: String, lessThan b: String) -> Bool {
        let pa = versionParts(a)
        let pb = versionParts(b)
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x < y { return true }
            if x > y { return false }
        }
        return false
    }

    private static func versionParts(_ v: String) -> [Int] {
        normalizeTag(v)
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }

    // MARK: - About UI

    static func presentAbout() {
        Task {
            let result = await checkLatest()
            presentAbout(result: result)
        }
    }

    static func presentAbout(result: CheckResult) {
        let alert = NSAlert()
        alert.messageText = "About Rise"
        alert.alertStyle = .informational

        let updateLine: String
        var openUpdateURL: URL?

        switch result {
        case .upToDate(let current, let latest):
            updateLine = "You’re up to date.\nLatest on GitHub: \(latest)  ·  This Mac: \(current)"
        case .updateAvailable(let current, let latest, let htmlURL):
            updateLine = "Update available: \(latest)\nThis Mac is on \(current).\n\nOpen Releases to download, then run install or replace Rise.app."
            openUpdateURL = htmlURL ?? releasesPage
        case .noPublishedVersion(let current):
            updateLine = "No GitHub releases published yet.\nThis Mac: \(current)\n\nWatch the repo for tags, or pull latest main and run scripts/install.sh."
        case .failed(let current, let message):
            updateLine = "Couldn’t check for updates.\nThis Mac: \(current)\n\n\(message)"
        }

        alert.informativeText = """
        Micro-breaks for desk work.

        Version \(currentVersion)  ·  build \(currentBuild)

        \(updateLine)

        github.com/\(repoSlug)
        """

        if openUpdateURL != nil {
            alert.addButton(withTitle: "Open Releases")
            alert.addButton(withTitle: "View Repo")
            alert.addButton(withTitle: "OK")
        } else {
            alert.addButton(withTitle: "View Repo")
            alert.addButton(withTitle: "OK")
        }

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if openUpdateURL != nil {
            switch response {
            case .alertFirstButtonReturn:
                if let url = openUpdateURL { NSWorkspace.shared.open(url) }
            case .alertSecondButtonReturn:
                NSWorkspace.shared.open(repoPage)
            default:
                break
            }
        } else if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(repoPage)
        }
    }
}
