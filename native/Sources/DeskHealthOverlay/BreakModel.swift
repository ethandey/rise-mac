import Foundation

enum DeskPosition: String, Codable, Equatable {
    case sitting
    case standing
    case unknown
}

/// Presentation intensity for a layer.
enum BreakSeverity: String, Codable, Equatable {
    /// Floating pill / extended popup — no full-screen dim.
    case soft
    /// Warning + full-screen checklist (home desk only).
    case firm
}

/// Where the user is working — drives content + presentation.
enum BreakVenue: String, Codable, Equatable {
    /// Home desk: firm overlays, standing desk, walks.
    case homeDesk
    /// Away (café etc.): soft extended popup, seated-friendly only.
    case cafe
}

struct BreakStep: Codable, Equatable, Identifiable {
    var id: String { "\(action)|\(detail)|\(duration)" }
    var action: String
    var detail: String
    var duration: String

    init(action: String, detail: String, duration: String) {
        self.action = action
        self.detail = detail
        self.duration = duration
    }

    static func fromPlain(_ text: String) -> BreakStep {
        let duration: String
        var body = text
        if let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close {
            duration = String(text[text.index(after: open)..<close])
            body = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        } else {
            duration = "—"
        }
        if let sep = body.range(of: " — ") ?? body.range(of: " - ") ?? body.range(of: ": ") {
            let action = String(body[..<sep.lowerBound]).trimmingCharacters(in: .whitespaces)
            let detail = String(body[sep.upperBound...]).trimmingCharacters(in: .whitespaces)
            return BreakStep(action: action.isEmpty ? body : action, detail: detail, duration: duration)
        }
        return BreakStep(action: body, detail: "", duration: duration)
    }
}

struct BreakModel: Codable, Equatable {
    var layer: String
    var title: String
    var subtitle: String
    var steps: [String]
    var tableSteps: [BreakStep]
    var durationHint: String
    var testMode: Bool
    var symbolName: String
    var intervalMinutes: Int
    var reason: String
    var severity: BreakSeverity
    /// If true, Done on this layer flips sit↔stand (desk switch).
    var flipsDeskPosition: Bool

    enum CodingKeys: String, CodingKey {
        case layer, title, subtitle, steps, reason, severity
        case tableSteps = "table_steps"
        case durationHint = "duration_hint"
        case testMode = "test_mode"
        case symbolName = "symbol_name"
        case intervalMinutes = "interval_minutes"
        case flipsDeskPosition = "flips_desk_position"
    }

    var displayRows: [BreakStep] {
        if !tableSteps.isEmpty { return tableSteps }
        return steps.map { BreakStep.fromPlain($0) }
    }

    init(
        layer: String,
        title: String,
        subtitle: String,
        steps: [String] = [],
        tableSteps: [BreakStep],
        durationHint: String,
        testMode: Bool,
        symbolName: String,
        intervalMinutes: Int,
        reason: String,
        severity: BreakSeverity,
        flipsDeskPosition: Bool = false
    ) {
        self.layer = layer
        self.title = title
        self.subtitle = subtitle
        self.steps = steps
        self.tableSteps = tableSteps
        self.durationHint = durationHint
        self.testMode = testMode
        self.symbolName = symbolName
        self.intervalMinutes = intervalMinutes
        self.reason = reason
        self.severity = severity
        self.flipsDeskPosition = flipsDeskPosition
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layer = try c.decodeIfPresent(String.self, forKey: .layer) ?? "A"
        let pos = DeskPosition.sitting
        let fallback = BreakModel.builtin(layer: layer, position: pos, testMode: false)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? fallback.title
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? fallback.subtitle
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        tableSteps = try c.decodeIfPresent([BreakStep].self, forKey: .tableSteps) ?? []
        if tableSteps.isEmpty && steps.isEmpty { tableSteps = fallback.tableSteps }
        durationHint = try c.decodeIfPresent(String.self, forKey: .durationHint) ?? fallback.durationHint
        testMode = try c.decodeIfPresent(Bool.self, forKey: .testMode) ?? false
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? fallback.symbolName
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? fallback.intervalMinutes
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? fallback.reason
        if let raw = try c.decodeIfPresent(String.self, forKey: .severity),
           let s = BreakSeverity(rawValue: raw) {
            severity = s
        } else {
            severity = fallback.severity
        }
        flipsDeskPosition = try c.decodeIfPresent(Bool.self, forKey: .flipsDeskPosition) ?? false
    }

    var cadenceLabel: String {
        "Every \(intervalMinutes) minutes"
    }

    var windowLabel: String {
        "\(intervalMinutes)-minute window"
    }

    // MARK: - Builtins (desk-only health; walk-first; posture-aware)

    static func builtin(
        layer: String,
        position: DeskPosition = .sitting,
        testMode: Bool = false,
        venue: BreakVenue = .homeDesk
    ) -> BreakModel {
        let pos = position == .unknown ? .sitting : position
        if venue == .cafe {
            return cafeBuiltin(layer: layer, testMode: testMode)
        }
        switch layer.uppercased() {
        case "B":
            return postureChange(position: pos, testMode: testMode)
        case "C":
            return leaveDeskWalk(testMode: testMode)
        case "S":
            return deskSwitch(position: pos, testMode: testMode)
        default:
            return eyesSoft(position: pos, testMode: testMode)
        }
    }

    static func testSequence(position: DeskPosition = .sitting) -> [BreakModel] {
        ["A", "B", "C"].map { builtin(layer: $0, position: position, testMode: true) }
    }

    /// Café / away: always soft, seated-friendly, no standing-desk or leave-building demands.
    private static func cafeBuiltin(layer: String, testMode: Bool) -> BreakModel {
        switch layer.uppercased() {
        case "B":
            return BreakModel(
                layer: "B",
                title: "Café reset",
                subtitle: "Seated · every 40 minutes",
                tableSteps: [
                    BreakStep(action: "Eyes", detail: "Look far across the room / window", duration: "20s"),
                    BreakStep(action: "Spine", detail: "Sit tall, uncurl from laptop hunch", duration: "10s"),
                    BreakStep(action: "Shoulders", detail: "Drop + slow scap squeezes", duration: "×5"),
                    BreakStep(action: "Neck", detail: "Gentle side bend, both sides — no cracking", duration: "15s"),
                    BreakStep(action: "Wrists", detail: "Open/close fists, prayer stretch if quiet", duration: "15s"),
                    BreakStep(action: "Ankles", detail: "Circle both feet under the table", duration: "10s"),
                ],
                durationHint: "About 90 seconds · stay seated",
                testMode: testMode,
                symbolName: "cup.and.saucer",
                intervalMinutes: 40,
                reason: "Away from desk — soft seated unload, no full-screen",
                severity: .soft,
                flipsDeskPosition: false
            )
        case "C":
            return BreakModel(
                layer: "C",
                title: "Café move",
                subtitle: "Optional stand · every 90 minutes",
                tableSteps: [
                    BreakStep(action: "Stand", detail: "If you can: stand at table or stretch up", duration: "30s"),
                    BreakStep(action: "Walk", detail: "Bathroom, counter, or outside loop if easy", duration: "2–3 min"),
                    BreakStep(action: "Or seated", detail: "Hip shifts, ankle pumps, chest open in chair", duration: "1 min"),
                    BreakStep(action: "Eyes", detail: "Long gaze outdoors or across the room", duration: "20s"),
                    BreakStep(action: "Water", detail: "Sip water before you dive back in", duration: "—"),
                ],
                durationHint: "2–3 minutes · café-friendly",
                testMode: testMode,
                symbolName: "figure.walk",
                intervalMinutes: 90,
                reason: "Longer away-from-desk reset without demanding a real walk",
                severity: .soft,
                flipsDeskPosition: false
            )
        case "S":
            // Standing desk not available out — same as café Change
            return cafeBuiltin(layer: "B", testMode: testMode)
        default:
            return BreakModel(
                layer: "A",
                title: "Eyes",
                subtitle: "Café · every 25 minutes",
                tableSteps: [
                    BreakStep(action: "Gaze", detail: "Look far — window or end of room", duration: "20s"),
                    BreakStep(action: "Blink", detail: "Full soft blinks", duration: "×5"),
                    BreakStep(action: "Posture", detail: "Unhunch, drop shoulders, soft chin tuck", duration: "5s"),
                ],
                durationHint: "About 30 seconds",
                testMode: testMode,
                symbolName: "eye",
                intervalMinutes: 25,
                reason: "Near-work reset while out",
                severity: .soft,
                flipsDeskPosition: false
            )
        }
    }

    /// Soft eyes — no full-screen by design.
    private static func eyesSoft(position: DeskPosition, testMode: Bool) -> BreakModel {
        let postureDetail = position == .standing
            ? "Stand tall, soft knees, drop shoulders"
            : "Sit tall, chin soft double-chin, drop shoulders"
        return BreakModel(
            layer: "A",
            title: "Eyes",
            subtitle: "Every 25 minutes",
            tableSteps: [
                BreakStep(action: "Gaze", detail: "Look ~20 ft / 6 m away — soft focus", duration: "20s"),
                BreakStep(action: "Blink", detail: "Full soft blinks, complete close", duration: "×5"),
                BreakStep(action: "Posture", detail: postureDetail, duration: "5s"),
            ],
            durationHint: "About 30 seconds",
            testMode: testMode,
            symbolName: "eye",
            intervalMinutes: 25,
            reason: "Near-work reset — accommodation + blink",
            severity: .soft
        )
    }

    /// Firm posture change + short mobility (includes eyes).
    private static func postureChange(position: DeskPosition, testMode: Bool) -> BreakModel {
        if position == .standing {
            return BreakModel(
                layer: "B",
                title: "Change + Move",
                subtitle: "Unload standing · every 40 minutes",
                tableSteps: [
                    BreakStep(action: "Eyes", detail: "Far gaze + full blinks", duration: "15s"),
                    BreakStep(action: "Switch", detail: "Lower desk to sit — or walk 60s", duration: "1 min"),
                    BreakStep(action: "Weight shift", detail: "If still standing: soft knees, L/R load", duration: "20s"),
                    BreakStep(action: "Calves / hips", detail: "Calf stretch or gentle hip hinge", duration: "20s"),
                    BreakStep(action: "Shoulders", detail: "Scap squeezes, unshrug", duration: "×5"),
                ],
                durationHint: "About 90 seconds",
                testMode: testMode,
                symbolName: "figure.cooldown",
                intervalMinutes: 40,
                reason: "Brain + body — break static standing load",
                severity: .firm,
                flipsDeskPosition: true
            )
        }
        return BreakModel(
            layer: "B",
            title: "Change + Move",
            subtitle: "Unload sitting · every 40 minutes",
            tableSteps: [
                BreakStep(action: "Eyes", detail: "Far gaze + full blinks", duration: "15s"),
                BreakStep(action: "Switch", detail: "Raise desk to stand — or walk 60s", duration: "1 min"),
                BreakStep(action: "Chest", detail: "Open chest, clasp hands behind back", duration: "15s"),
                BreakStep(action: "Hips", detail: "Hip flexor stretch or walk in place", duration: "20s"),
                BreakStep(action: "Neck", detail: "Gentle side bend both sides", duration: "15s"),
            ],
            durationHint: "About 90 seconds",
            testMode: testMode,
            symbolName: "figure.stand",
            intervalMinutes: 40,
            reason: "Brain + body — break static sitting load",
            severity: .firm,
            flipsDeskPosition: true
        )
    }

    /// Leave-desk walk — primary brain/circulation reset (not a second workout).
    private static func leaveDeskWalk(testMode: Bool) -> BreakModel {
        BreakModel(
            layer: "C",
            title: "Walk break",
            subtitle: "Leave the desk · every 90 minutes",
            tableSteps: [
                BreakStep(action: "Leave", detail: "Step away from the screen completely", duration: "—"),
                BreakStep(action: "Walk", detail: "Hall, stairs, or outdoors — easy pace", duration: "3–5 min"),
                BreakStep(action: "Eyes", detail: "Look at distance / horizon while walking", duration: "ongoing"),
                BreakStep(action: "Water", detail: "Drink water before you sit again", duration: "—"),
            ],
            durationHint: "3–5 minutes",
            testMode: testMode,
            symbolName: "figure.walk",
            intervalMinutes: 90,
            reason: "Brain blood flow + real movement — not another workout",
            severity: .firm
        )
    }

    /// Explicit desk height switch (standing-desk mode).
    private static func deskSwitch(position: DeskPosition, testMode: Bool) -> BreakModel {
        let toStand = position != .standing
        return BreakModel(
            layer: "S",
            title: toStand ? "Switch to standing" : "Switch to sitting",
            subtitle: "Desk height · ~every 30 minutes",
            tableSteps: [
                BreakStep(
                    action: "Desk",
                    detail: toStand ? "Raise desk to standing height" : "Lower desk to sitting height",
                    duration: "—"
                ),
                BreakStep(
                    action: "Settle",
                    detail: toStand ? "Soft knees, even weight, screen at eye line" : "Feet flat, sit bones, screen at eye line",
                    duration: "15s"
                ),
                BreakStep(action: "Eyes", detail: "Far gaze once, then resume", duration: "10s"),
            ],
            durationHint: "About 30 seconds",
            testMode: testMode,
            symbolName: "arrow.up.arrow.down",
            intervalMinutes: 30,
            reason: "Change load — sit and stand are both tools",
            severity: .firm,
            flipsDeskPosition: true
        )
    }

    static func load(from path: String) throws -> BreakModel {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BreakModel.self, from: data)
    }
}

enum BreakAction: Equatable {
    case done
    case skip
    case snooze(minutes: Int)

    var stdoutToken: String {
        switch self {
        case .done: return "done"
        case .skip: return "skip"
        case .snooze(let m): return "snooze:\(m)"
        }
    }
}

enum LaunchMode: Equatable {
    case menuBar(autoSequence: [BreakModel]?)
    case oneShot(models: [BreakModel])
}
