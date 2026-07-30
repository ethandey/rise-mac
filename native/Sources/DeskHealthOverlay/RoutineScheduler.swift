import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "app.rise.menubar", category: "scheduler")

/// Native break routine — A/B/C intervals with work hours 07:00–20:00, home geofence, snooze.
@MainActor
final class RoutineScheduler: ObservableObject {
    static let shared = RoutineScheduler()

    struct Config: Equatable {
        var enabled: Bool = true
        var workdayStart: String = "07:00"
        var workdayEnd: String = "20:00"
        var quietLunch: Bool = false
        var quietLunchStart: String = "12:00"
        var quietLunchEnd: String = "13:00"
        var intervals: [String: Int] = ["A": 20, "B": 40, "C": 90]
        var snoozeMinutes: Int = 5
    }

    @Published private(set) var config = Config()
    @Published private(set) var lastA: Date?
    @Published private(set) var lastB: Date?
    @Published private(set) var lastC: Date?
    @Published private(set) var snoozeUntil: Date?
    @Published private(set) var now: Date = Date()
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var lastSkipReason: String?

    var onLayerDue: ((String) -> Bool)?

    private var timer: Timer?
    private var lastFiredMinute: String?
    private let statePath: String

    private init() {
        let root = SystemControl.root
        let data = (root as NSString).appendingPathComponent("data")
        try? FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        statePath = (data as NSString).appendingPathComponent("rise-routine.json")
        loadConfig()
        loadState()
        clearExpiredSnooze()
        // Seed last_* so first A is ~interval later (not an instant blast on install)
        let n = Date()
        if lastA == nil { lastA = n }
        if lastB == nil { lastB = n }
        if lastC == nil { lastC = n }
        saveState()
        log.info("scheduler ready work=\(self.config.workdayStart, privacy: .public)–\(self.config.workdayEnd, privacy: .public)")
    }

    func start() {
        stop()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        // Run immediately so overdue layers fire without waiting a full minute
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Countdown API

    func interval(for layer: String) -> Int {
        config.intervals[layer] ?? ["A": 20, "B": 40, "C": 90][layer] ?? 20
    }

    func lastFire(for layer: String) -> Date? {
        switch layer {
        case "A": return lastA
        case "B": return lastB
        case "C": return lastC
        default: return nil
        }
    }

    func nextDue(for layer: String) -> Date {
        let last = lastFire(for: layer) ?? now
        return last.addingTimeInterval(TimeInterval(interval(for: layer) * 60))
    }

    func secondsUntil(layer: String) -> TimeInterval {
        max(0, nextDue(for: layer).timeIntervalSince(now))
    }

    var nextLayer: String {
        let layers = ["A", "B", "C"]
        return layers.min { secondsUntil(layer: $0) < secondsUntil(layer: $1) } ?? "A"
    }

    var nextSeconds: TimeInterval {
        secondsUntil(layer: nextLayer)
    }

    func formatCountdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    func formatNotifyTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    func layerTitle(_ layer: String) -> String {
        switch layer {
        case "A": return "Eyes"
        case "B": return "Stretch"
        case "C": return "Bands"
        default: return layer
        }
    }

    var idleReason: String? {
        if isPaused { return "Paused" }
        if let until = snoozeUntil, until > now {
            return "Snoozed · \(formatCountdown(until.timeIntervalSince(now))) left"
        }
        if !config.enabled { return "Schedule off" }
        if !inWorkWindow(now) {
            return "Outside hours (\(config.workdayStart)–\(config.workdayEnd))"
        }
        if inQuietLunch(now) { return "Quiet lunch" }
        if !LocationManager.shared.allowsRoutine {
            let loc = LocationManager.shared
            if loc.status == .away, let d = loc.distanceFromHome {
                return String(format: "Away from home (%.0f m · need ≤%.0f m)", d, loc.homeRadius)
            }
            return loc.status.menuLabel
        }
        return nil
    }

    // MARK: - Mutations

    func markCompleted(layer: String) {
        let n = Date()
        switch layer {
        case "C":
            lastC = n; lastB = n; lastA = n
        case "B":
            lastB = n; lastA = n
        default:
            lastA = n
        }
        saveState()
        log.info("completed layer \(layer, privacy: .public)")
    }

    func snooze(minutes: Int) {
        snoozeUntil = Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        saveState()
        log.info("snoozed \(minutes)m until \(self.snoozeUntil!.description, privacy: .public)")
    }

    func clearSnooze() {
        snoozeUntil = nil
        saveState()
    }

    // MARK: - Tick

    private func tick() {
        now = Date()
        clearExpiredSnooze()
        objectWillChange.send()

        guard config.enabled, !isPaused else {
            lastSkipReason = isPaused ? "paused" : "disabled"
            return
        }
        guard LocationManager.shared.allowsRoutine else {
            lastSkipReason = "location:\(LocationManager.shared.status.menuLabel)"
            return
        }
        if let until = snoozeUntil, until > now {
            lastSkipReason = "snoozed"
            return
        }
        guard inWorkWindow(now) else {
            lastSkipReason = "outside work hours"
            return
        }
        guard !inQuietLunch(now) else {
            lastSkipReason = "quiet lunch"
            return
        }

        // Find highest-priority due layer
        var dueLayer: String?
        for layer in ["C", "B", "A"] {
            if secondsUntil(layer: layer) <= 0 {
                dueLayer = layer
                break
            }
        }
        guard let layer = dueLayer else {
            lastSkipReason = nil
            return
        }

        // At most one auto-fire per wall-clock minute (set only when we actually hand off)
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let minuteKey = df.string(from: now)
        if minuteKey == lastFiredMinute {
            lastSkipReason = "already fired this minute"
            return
        }

        lastSkipReason = nil
        log.info("firing layer \(layer, privacy: .public)")
        if let handler = onLayerDue {
            let started = handler(layer)
            if started {
                lastFiredMinute = minuteKey
            } else {
                lastSkipReason = "handler busy"
                log.info("layer \(layer, privacy: .public) not accepted — will retry")
            }
        }
    }

    private func clearExpiredSnooze() {
        if let until = snoozeUntil, until <= now {
            snoozeUntil = nil
            saveState()
            log.info("cleared expired snooze")
        }
    }

    // MARK: - Work window (07:00–20:00)

    private func inWorkWindow(_ date: Date) -> Bool {
        guard let start = timeToday(config.workdayStart, on: date),
              let end = timeToday(config.workdayEnd, on: date) else { return true }
        return date >= start && date < end
    }

    private func inQuietLunch(_ date: Date) -> Bool {
        guard config.quietLunch,
              let start = timeToday(config.quietLunchStart, on: date),
              let end = timeToday(config.quietLunchEnd, on: date) else { return false }
        return date >= start && date < end
    }

    private func timeToday(_ hhmm: String, on date: Date) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        var cal = Calendar.current
        cal.timeZone = .current
        var c = cal.dateComponents([.year, .month, .day], from: date)
        c.hour = parts[0]
        c.minute = parts[1]
        c.second = 0
        return cal.date(from: c)
    }

    // MARK: - Persistence

    private func loadConfig() {
        let path = (SystemControl.root as NSString)
            .appendingPathComponent("data/config.json")
        let fallback = (SystemControl.root as NSString)
            .appendingPathComponent("data/config.default.json")
        let url = FileManager.default.fileExists(atPath: path)
            ? URL(fileURLWithPath: path)
            : URL(fileURLWithPath: fallback)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }

        var c = Config()
        if let v = json["enabled"] as? Bool { c.enabled = v }
        if let v = json["workday_start"] as? String { c.workdayStart = v }
        if let v = json["workday_end"] as? String { c.workdayEnd = v }
        if let v = json["quiet_lunch"] as? Bool { c.quietLunch = v }
        if let v = json["quiet_lunch_start"] as? String { c.quietLunchStart = v }
        if let v = json["quiet_lunch_end"] as? String { c.quietLunchEnd = v }
        if let v = json["snooze_minutes"] as? Int { c.snoozeMinutes = v }
        if let intervals = json["intervals"] as? [String: Any] {
            var map: [String: Int] = c.intervals
            for (k, val) in intervals {
                if let i = val as? Int { map[k] = i }
                else if let i = val as? NSNumber { map[k] = i.intValue }
            }
            c.intervals = map
        }
        config = c
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        func parse(_ s: String?) -> Date? {
            guard let s else { return nil }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s) { return d }
            // Fallback: "2026-07-30T01:06:11Z"
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssX"
            return f.date(from: s)
        }
        lastA = parse(json["last_A"] as? String)
        lastB = parse(json["last_B"] as? String)
        lastC = parse(json["last_C"] as? String)
        snoozeUntil = parse(json["snooze_until"] as? String)
        isPaused = (json["paused"] as? Bool) ?? false
    }

    private func saveState() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        func fmt(_ d: Date?) -> String? {
            guard let d else { return nil }
            return iso.string(from: d)
        }
        var dict: [String: Any] = ["paused": isPaused]
        if let s = fmt(lastA) { dict["last_A"] = s }
        if let s = fmt(lastB) { dict["last_B"] = s }
        if let s = fmt(lastC) { dict["last_C"] = s }
        if let s = fmt(snoozeUntil) { dict["snooze_until"] = s }
        else { dict["snooze_until"] = NSNull() }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        }
    }
}
