import Foundation
import Combine
import os.log

private let log = Logger(subsystem: "app.rise.menubar", category: "scheduler")

/// Desk-time clocks run on *active computer use*, not wall clock.
/// Suppresses “just sat down → do exercises” and mid-flow firm takeovers.
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
        var intervalA: Int = 25
        var intervalB: Int = 40
        var intervalC: Int = 90
        var intervalS: Int = 30
        var snoozeMinutes: Int = 5
        var hasStandingDesk: Bool = true
        /// Hard caps: continuous minutes *in posture while active at Mac*
        var maxSitMinutes: Int = 55
        var maxStandMinutes: Int = 35
        /// After sit/stand change, don't ask to switch again this soon
        var minDwellMinutes: Int = 15
        /// After sitting down, never immediately demand stand/exercises
        var settleMinutes: Int = 12
    }

    @Published private(set) var config = Config()
    @Published private(set) var deskPosition: DeskPosition = .sitting
    @Published private(set) var lastPositionChange: Date?
    @Published private(set) var snoozeUntil: Date?
    @Published private(set) var now: Date = Date()
    @Published private(set) var isPaused: Bool = false
    @Published private(set) var lastSkipReason: String?

    /// Active-seconds accrued toward each layer (pause when idle).
    @Published private(set) var activeA: TimeInterval = 0
    @Published private(set) var activeB: TimeInterval = 0
    @Published private(set) var activeC: TimeInterval = 0
    @Published private(set) var activeS: TimeInterval = 0
    /// Active seconds in current sit/stand posture.
    @Published private(set) var activeInPosition: TimeInterval = 0

    var onLayerDue: ((String) -> Bool)?

    private var timer: Timer?
    private var lastTick: Date = Date()
    private var lastFiredMinute: String?
    /// Tracks work-window edge so morning open gets firm grace (no “do exercises at 7:00”).
    private var wasInWorkWindow: Bool = false
    private let statePath: String
    private let activity = ActivityMonitor.shared

    private init() {
        let root = SystemControl.root
        let data = (root as NSString).appendingPathComponent("data")
        try? FileManager.default.createDirectory(atPath: data, withIntermediateDirectories: true)
        statePath = (data as NSString).appendingPathComponent("rise-routine.json")
        loadConfig()
        loadState()
        clearExpiredSnooze()
        if lastPositionChange == nil { lastPositionChange = Date() }
        saveState()
    }

    func start() {
        stop()
        activity.start()
        lastTick = Date()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        activity.stop()
    }

    // MARK: - Countdown (based on remaining active time)

    func interval(for layer: String) -> Int {
        switch layer.uppercased() {
        case "B": return config.intervalB
        case "C": return config.intervalC
        case "S": return config.intervalS
        default: return config.intervalA
        }
    }

    private func activeAccrued(for layer: String) -> TimeInterval {
        switch layer.uppercased() {
        case "B": return activeB
        case "C": return activeC
        case "S": return activeS
        default: return activeA
        }
    }

    func secondsUntil(layer: String) -> TimeInterval {
        let need = TimeInterval(interval(for: layer) * 60)
        return max(0, need - activeAccrued(for: layer))
    }

    /// Wall-clock estimate of fire time if user stays active.
    func nextDue(for layer: String) -> Date {
        now.addingTimeInterval(secondsUntil(layer: layer))
    }

    /// Café / away: no standing-desk Switch layer.
    var isCafeMode: Bool { LocationManager.shared.isCafeMode }

    var scheduledLayers: [String] {
        if isCafeMode { return ["A", "B", "C"] }
        return hasStandingDeskEffective ? ["A", "B", "S", "C"] : ["A", "B", "C"]
    }

    var breakVenue: BreakVenue {
        // Home and office share the same full desk routine
        isCafeMode ? .cafe : .homeDesk
    }

    var nextLayer: String {
        scheduledLayers.min { secondsUntil(layer: $0) < secondsUntil(layer: $1) } ?? "A"
    }

    func formatCountdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    /// Whole active minutes remaining (ceil so “1 min” shows until the last second).
    func minutesUntil(layer: String) -> Int {
        let sec = secondsUntil(layer: layer)
        if sec <= 0 { return 0 }
        return max(1, Int(ceil(sec / 60.0)))
    }

    /// Calm menu label: “18 min” / “due”.
    func formatMinutesLeft(layer: String) -> String {
        let m = minutesUntil(layer: layer)
        if m <= 0 { return "due" }
        if m == 1 { return "1 min" }
        return "\(m) min"
    }

    func formatNotifyTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }

    func layerTitle(_ layer: String) -> String {
        if isCafeMode {
            switch layer.uppercased() {
            case "B": return "Café reset"
            case "C": return "Café move"
            default: return "Eyes"
            }
        }
        switch layer.uppercased() {
        case "B": return "Change"
        case "C": return "Walk"
        case "S": return deskPosition == .standing ? "Sit" : "Stand"
        default: return "Eyes"
        }
    }

    var minutesInPosition: Int {
        Int(activeInPosition / 60)
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
            return LocationManager.shared.status.menuLabel
        }
        // Presence / credit — prefer live activity label over generic
        if !activity.isActivelyUsing || activity.shouldSuppressPrompts {
            return activity.presenceLabel
        }
        return nil
    }

    // MARK: - Desk position

    /// Standing desk follows current place (home / office). Café = off.
    var hasStandingDeskEffective: Bool {
        if isCafeMode { return false }
        return LocationManager.shared.standingDeskForCurrentPlace
    }

    func setHasStandingDesk(_ on: Bool) {
        // Toggle for the place you’re at; if none, set home preference
        let loc = LocationManager.shared
        switch loc.status {
        case .atOffice:
            loc.setStandingDesk(for: .office, enabled: on)
        case .atHome:
            loc.setStandingDesk(for: .home, enabled: on)
        default:
            // Fallback: home if set, else office, else home default
            if loc.homeSet {
                loc.setStandingDesk(for: .home, enabled: on)
            } else if loc.officeSet {
                loc.setStandingDesk(for: .office, enabled: on)
            } else {
                loc.setStandingDesk(for: .home, enabled: on)
            }
        }
        config.hasStandingDesk = on
        objectWillChange.send()
    }

    /// Sync effective standing desk from location into config (menu + schedule).
    func syncStandingDeskFromLocation() {
        let on = hasStandingDeskEffective
        if config.hasStandingDesk != on {
            config.hasStandingDesk = on
            objectWillChange.send()
        }
    }

    func setDeskPosition(_ position: DeskPosition) {
        guard position != .unknown, position != deskPosition else {
            if position != .unknown { deskPosition = position }
            return
        }
        deskPosition = position
        lastPositionChange = Date()
        activeInPosition = 0
        // Just sat / just stood: reset switch clock so we don't nag immediately
        activeS = 0
        // Soft-reset change timer partially so B doesn't fire "stand" the second you sit
        activeB = min(activeB, TimeInterval(config.settleMinutes * 60) * 0.25)
        saveState()
        objectWillChange.send()
        log.info("posture → \(position.rawValue, privacy: .public)")
    }

    func flipDeskPosition() {
        setDeskPosition(deskPosition == .standing ? .sitting : .standing)
    }

    // MARK: - Complete / snooze

    func markCompleted(layer: String, action: BreakAction) {
        switch layer.uppercased() {
        case "C":
            activeC = 0
            activeB = 0
            activeA = 0
            // Real walk = significant break; firm grace
            activity.noteDeliberateBreak()
        case "B":
            activeB = 0
            activeA = 0
            if action == .done {
                // Home desk + standing desk: Done may flip posture. Café: never.
                if !isCafeMode, hasStandingDeskEffective {
                    flipDeskPosition()
                } else {
                    activeInPosition = 0
                }
            }
            activity.noteDeliberateBreak()
        case "S":
            activeS = 0
            activeA = 0
            if action == .done, !isCafeMode {
                flipDeskPosition()
            }
            activity.noteDeliberateBreak()
        default:
            activeA = 0
        }
        activity.clearFirmDefer()
        saveState()
        log.info("completed \(layer, privacy: .public)")
    }

    func snooze(minutes: Int) {
        snoozeUntil = Date().addingTimeInterval(TimeInterval(max(1, minutes) * 60))
        activity.clearFirmDefer()
        saveState()
    }

    // MARK: - Tick

    private func tick() {
        now = Date()
        clearExpiredSnooze()
        syncStandingDeskFromLocation()

        let dt = max(0, now.timeIntervalSince(lastTick))
        lastTick = now

        let inWork = inWorkWindow(now)
        // Entering the workday (or first tick after launch inside hours) → settle in
        if inWork, !wasInWorkWindow {
            activity.noteSessionStart()
            // Don't carry overnight near-due debt into the first minutes of the day
            activeA = 0
            activeB = 0
            activeC = 0
            activeS = 0
            activeInPosition = 0
            log.info("work window open — clocks + firm grace reset")
        }
        wasInWorkWindow = inWork

        // Leaving the keyboard *is* the break — forgive debt, don't bank it
        applyAwayCreditIfNeeded()

        // Accrue only while actively using the computer
        if shouldAccrueDeskTime() {
            activeA += dt
            activeB += dt
            activeC += dt
            if hasStandingDeskEffective { activeS += dt }
            activeInPosition += dt
        }

        objectWillChange.send()

        guard config.enabled, !isPaused else {
            lastSkipReason = isPaused ? "paused" : "disabled"
            return
        }
        guard LocationManager.shared.allowsRoutine else {
            lastSkipReason = "location"
            return
        }
        if let until = snoozeUntil, until > now {
            lastSkipReason = "snoozed"
            return
        }
        guard inWork else {
            lastSkipReason = "outside hours"
            return
        }
        guard !inQuietLunch(now) else {
            lastSkipReason = "lunch"
            return
        }

        // Video / AFK / reading — never interrupt (debt does not "come due" while passive)
        if activity.shouldSuppressPrompts {
            lastSkipReason = "passive / away — no prompts"
            return
        }

        // Hard posture caps — home desk only (café has no stand/sit hardware)
        if !isCafeMode, hasStandingDeskEffective {
            let maxPos = deskPosition == .standing
                ? TimeInterval(config.maxStandMinutes * 60)
                : TimeInterval(config.maxSitMinutes * 60)
            if activeInPosition >= maxPos {
                tryFire(layer: "B", firm: true)
                return
            }
        }

        // Priority C > S > B > A (S omitted in café mode)
        var order = ["C", "B", "A"]
        if !isCafeMode, hasStandingDeskEffective { order = ["C", "S", "B", "A"] }

        for layer in order {
            if secondsUntil(layer: layer) > 0 { continue }
            if layer == "S", !canFireSwitch() { continue }
            if layer == "B", !canFireChange() { continue }

            // Café: always soft presentation (no full-screen firm)
            let firm = !isCafeMode && layer != "A"
            tryFire(layer: layer, firm: firm)
            return
        }
        lastSkipReason = nil
    }

    /// Absence credits movement — do not make the user "pay" old active-seconds on return.
    private func applyAwayCreditIfNeeded() {
        let credit = activity.consumeAwayCredit()
        guard credit != .none else { return }
        switch credit {
        case .walk:
            // Real walk / long break: full cycle credit
            activeA = 0
            activeB = 0
            activeC = 0
            activeS = 0
            activeInPosition = 0
            log.info("away credit: walk — all clocks forgiven")
        case .movement:
            // Stood up / short walk: Change + Switch done; keep some Walk progress
            activeA = 0
            activeB = 0
            activeS = 0
            activeInPosition = 0
            // Walk progress: keep at most half an interval so a coffee run doesn't wipe C
            let halfC = TimeInterval(config.intervalC * 60) * 0.5
            activeC = min(activeC, halfC)
            log.info("away credit: movement — B/S/A forgiven, C capped")
        case .none:
            break
        }
        saveState()
    }

    private func shouldAccrueDeskTime() -> Bool {
        guard activity.isActivelyUsing else { return false }
        guard inWorkWindow(now), !inQuietLunch(now) else { return false }
        guard LocationManager.shared.allowsRoutine else { return false }
        if let until = snoozeUntil, until > now { return false }
        return config.enabled && !isPaused
    }

    /// Don't ask to change posture right after they just sat/stood.
    private func canFireChange() -> Bool {
        let settle = TimeInterval(config.settleMinutes * 60)
        if activeInPosition < settle {
            lastSkipReason = "settling into posture"
            return false
        }
        return true
    }

    private func canFireSwitch() -> Bool {
        guard hasStandingDeskEffective else { return false }
        let dwell = TimeInterval(config.minDwellMinutes * 60)
        if activeInPosition < dwell {
            lastSkipReason = "min dwell"
            return false
        }
        return true
    }

    private func tryFire(layer: String, firm: Bool) {
        // Never during video / deep idle
        if activity.shouldSuppressPrompts {
            lastSkipReason = "passive / away — no prompts"
            return
        }
        // Only interrupt while actually at the keyboard (active bout)
        if !activity.isActivelyUsing {
            lastSkipReason = "not at keyboard"
            return
        }
        // Session settle after wake / workday open / long-credit return
        if firm, activity.inFirmGrace {
            lastSkipReason = "firm grace (settling in)"
            return
        }
        if !firm, activity.inSoftGrace {
            lastSkipReason = "soft grace"
            return
        }
        // Firm only on a short natural pause (2.5s–45s), not mid-keystroke or deep idle
        if firm, activity.shouldDeferFirmForFlow(now: now) {
            lastSkipReason = "waiting for natural pause"
            return
        }

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm"
        let minuteKey = df.string(from: now)
        if minuteKey == lastFiredMinute {
            lastSkipReason = "already fired this minute"
            return
        }

        guard let handler = onLayerDue else { return }
        let started = handler(layer)
        if started {
            lastFiredMinute = minuteKey
            lastSkipReason = nil
            activity.clearFirmDefer()
            log.info("fired \(layer, privacy: .public) firm=\(firm)")
        } else {
            lastSkipReason = "handler busy"
        }
    }

    private func clearExpiredSnooze() {
        if let until = snoozeUntil, until <= now {
            snoozeUntil = nil
            saveState()
        }
    }

    // MARK: - Work window

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
        let path = (SystemControl.root as NSString).appendingPathComponent("data/config.json")
        let fallback = (SystemControl.root as NSString).appendingPathComponent("data/config.default.json")
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
        if let v = json["has_standing_desk"] as? Bool { c.hasStandingDesk = v }
        if let intervals = json["intervals"] as? [String: Any] {
            if let a = intVal(intervals["A"]) { c.intervalA = a == 20 ? 25 : a }
            if let b = intVal(intervals["B"]) { c.intervalB = b }
            if let cInt = intVal(intervals["C"]) { c.intervalC = cInt }
            if let s = intVal(intervals["S"]) { c.intervalS = s }
        }
        if UserDefaults.standard.object(forKey: "rise.desk.hasStanding") != nil {
            c.hasStandingDesk = UserDefaults.standard.bool(forKey: "rise.desk.hasStanding")
        }
        config = c
    }

    private func intVal(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: statePath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        if let p = json["desk_position"] as? String, let d = DeskPosition(rawValue: p) {
            deskPosition = d
        }
        // Active seconds don't survive restarts well as wall times — reset clocks
        activeA = 0
        activeB = 0
        activeC = 0
        activeS = 0
        activeInPosition = 0
        isPaused = (json["paused"] as? Bool) ?? false
        // Parse snooze if still valid
        if let s = json["snooze_until"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            if let d = iso.date(from: s), d > Date() {
                snoozeUntil = d
            }
        }
    }

    private func saveState() {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var dict: [String: Any] = [
            "paused": isPaused,
            "desk_position": deskPosition.rawValue,
        ]
        if let s = snoozeUntil {
            dict["snooze_until"] = iso.string(from: s)
        }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
        }
    }
}
