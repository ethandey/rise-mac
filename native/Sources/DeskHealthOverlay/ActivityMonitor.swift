import AppKit
import CoreGraphics
import Foundation

/// Computer presence from real input idle (same family as screensaver / energy saver).
///
/// Model (not “banked debt”):
/// - **Active** (idle &lt; ~90s): desk-work clocks run.
/// - **Passive** (idle ~45s+): video / reading / still — **never prompt**.
/// - **Stepped away** (~4 min): movement credit — forgive Change/Switch debt.
/// - **Walked away** (~8 min): walk credit — forgive Walk debt too.
///
/// Leaving the keyboard *is* the break. Coming back must not cash in old timers.
@MainActor
final class ActivityMonitor: ObservableObject {
    static let shared = ActivityMonitor()

    enum AwayCredit: Int, Comparable {
        case none = 0
        /// ~4+ min idle — stood up / short walk (covers Change + Switch).
        case movement = 1
        /// ~8+ min idle — real walk / long break (covers Walk too).
        case walk = 2

        static func < (lhs: AwayCredit, rhs: AwayCredit) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    @Published private(set) var idleSeconds: TimeInterval = 0
    @Published private(set) var isActivelyUsing: Bool = false
    @Published private(set) var activeBoutSeconds: TimeInterval = 0
    @Published private(set) var sessionStartedAt: Date = Date()
    @Published private(set) var lastBecameActiveAt: Date = Date()
    @Published private(set) var sessionActiveSeconds: TimeInterval = 0
    /// Highest away-credit earned in the current idle stretch (consumed by scheduler).
    @Published private(set) var awayCredit: AwayCredit = .none

    /// Idle longer than this → pause desk-time clocks.
    var idlePauseThreshold: TimeInterval = 90
    /// Idle longer than this → never show soft/firm prompts (video, AFK, reading).
    var suppressPromptIdle: TimeInterval = 45
    /// Idle this long → movement credit (forgive Change).
    var movementCreditIdle: TimeInterval = 4 * 60
    /// Idle this long → walk credit (forgive Walk).
    var walkCreditIdle: TimeInterval = 8 * 60
    /// Session settle disabled — away-credit + active clocks handle “just sat down”.
    var firmGraceSeconds: TimeInterval = 0
    var softGraceSeconds: TimeInterval = 0
    /// Mid-flow: need a short pause before firm UI (must stay *below* suppressPromptIdle).
    var naturalPauseIdle: TimeInterval = 2.5
    /// Don't defer firm forever while actively typing.
    var maxFirmDeferSeconds: TimeInterval = 10 * 60

    private var timer: Timer?
    private var lastTick: Date = Date()
    private var wasActive = false
    private var firmDueSince: Date?
    private var creditThisAway: AwayCredit = .none
    private var wakeObserver: NSObjectProtocol?
    private var unlockObserver: NSObjectProtocol?

    private init() {
        let now = Date()
        sessionStartedAt = now
        lastBecameActiveAt = now
        installWorkspaceObservers()
    }

    func start() {
        stop()
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
    }

    var secondsSinceFirmGraceAnchor: TimeInterval {
        Date().timeIntervalSince(max(sessionStartedAt, lastBecameActiveAt))
    }

    var inSoftGrace: Bool {
        secondsSinceFirmGraceAnchor < softGraceSeconds
    }

    var inFirmGrace: Bool {
        secondsSinceFirmGraceAnchor < firmGraceSeconds
    }

    /// True when we must not show any scheduled overlay (video / walked away / staring).
    var shouldSuppressPrompts: Bool {
        idleSeconds >= suppressPromptIdle
    }

    /// Firm takeover: only on a *short* natural pause while still in an active desk bout.
    /// Deep idle is NOT a fire window (that was the “bug me during Netflix” bug).
    func shouldDeferFirmForFlow(now: Date = Date()) -> Bool {
        if idleSeconds >= suppressPromptIdle {
            firmDueSince = nil
            return true // block — passive / away
        }
        if idleSeconds >= naturalPauseIdle {
            // 2.5s … suppressPromptIdle: good moment between typing bursts
            firmDueSince = nil
            return false
        }
        if firmDueSince == nil {
            firmDueSince = now
        }
        let waited = now.timeIntervalSince(firmDueSince ?? now)
        return waited < maxFirmDeferSeconds
    }

    func clearFirmDefer() {
        firmDueSince = nil
    }

    /// Scheduler calls after applying credit so we don't re-apply every second.
    func consumeAwayCredit() -> AwayCredit {
        let c = awayCredit
        awayCredit = .none
        return c
    }

    /// After a completed break — clear mid-flow defer only.
    func noteDeliberateBreak() {
        clearFirmDefer()
    }

    /// Workday open / wake — reset bout tracking (no “Settling in” grace).
    func noteSessionStart() {
        let now = Date()
        sessionStartedAt = now
        lastBecameActiveAt = now
        activeBoutSeconds = 0
        creditThisAway = .none
        awayCredit = .none
        clearFirmDefer()
    }

    var presenceLabel: String {
        if isActivelyUsing {
            return "At keyboard · clocks running"
        }
        if idleSeconds >= walkCreditIdle {
            return "Away · walk credited (no debt)"
        }
        if idleSeconds >= movementCreditIdle {
            return "Away · movement credited"
        }
        if idleSeconds >= suppressPromptIdle {
            return "Passive · no prompts (video / idle)"
        }
        return "Away from keyboard · clocks paused"
    }

    // MARK: - Private

    private func tick() {
        let now = Date()
        let dt = max(0, now.timeIntervalSince(lastTick))
        lastTick = now

        idleSeconds = Self.systemIdleSeconds()
        let active = idleSeconds < idlePauseThreshold

        if active {
            activeBoutSeconds += dt
            sessionActiveSeconds += dt
            if !wasActive {
                // Returned to keyboard — debt already forgiven via away credit
                creditThisAway = .none
            }
        } else {
            activeBoutSeconds = 0
            // Earn away credit while idle (idle *is* the break)
            if idleSeconds >= walkCreditIdle, creditThisAway < .walk {
                creditThisAway = .walk
                awayCredit = .walk
            } else if idleSeconds >= movementCreditIdle, creditThisAway < .movement {
                creditThisAway = .movement
                awayCredit = .movement
            }
        }

        isActivelyUsing = active
        wasActive = active
        objectWillChange.send()
    }

    private static func systemIdleSeconds() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .mouseMoved, .scrollWheel,
            .leftMouseDragged, .rightMouseDragged,
        ]
        var minIdle = TimeInterval.greatestFiniteMagnitude
        for t in types {
            let s = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t)
            if s.isFinite, s >= 0 {
                minIdle = min(minIdle, s)
            }
        }
        return minIdle == .greatestFiniteMagnitude ? 0 : minIdle
    }

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.noteSessionStart()
            }
        }
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.clearFirmDefer()
                // Unlock after being away → movement credit (forgive Change debt)
                if self.awayCredit < .movement {
                    self.awayCredit = .movement
                    self.creditThisAway = max(self.creditThisAway, .movement)
                }
            }
        }
    }
}
