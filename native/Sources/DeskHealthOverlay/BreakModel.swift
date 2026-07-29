import Foundation

/// One row in the break instruction table.
struct BreakStep: Codable, Equatable, Identifiable {
    var id: String { "\(action)|\(detail)|\(duration)" }
    /// Short action name (table column).
    var action: String
    /// How / cue (table column).
    var detail: String
    /// Time or reps (table column).
    var duration: String

    enum CodingKeys: String, CodingKey {
        case action, detail, duration
    }

    init(action: String, detail: String, duration: String) {
        self.action = action
        self.detail = detail
        self.duration = duration
    }

    /// Fallback when payload only has plain strings.
    static func fromPlain(_ text: String) -> BreakStep {
        // Try "Action — detail (duration)" or "Action: detail"
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

/// Payload the overlay renders. Can be loaded from JSON or built-in layers.
struct BreakModel: Codable, Equatable {
    var layer: String
    var title: String
    var subtitle: String
    /// Legacy plain steps (still accepted from Python payload).
    var steps: [String]
    /// Preferred structured rows for the table UI.
    var tableSteps: [BreakStep]
    var durationHint: String
    var testMode: Bool
    var symbolName: String
    var intervalMinutes: Int
    var reason: String

    enum CodingKeys: String, CodingKey {
        case layer, title, subtitle, steps, reason
        case tableSteps = "table_steps"
        case durationHint = "duration_hint"
        case testMode = "test_mode"
        case symbolName = "symbol_name"
        case intervalMinutes = "interval_minutes"
    }

    /// Rows to render: structured if present, else parse plain `steps`.
    var displayRows: [BreakStep] {
        if !tableSteps.isEmpty { return tableSteps }
        return steps.map { BreakStep.fromPlain($0) }
    }

    static func builtin(layer: String, testMode: Bool) -> BreakModel {
        switch layer.uppercased() {
        case "B":
            return BreakModel(
                layer: "B",
                title: "Stand + Stretch",
                subtitle: "Every 40 minutes",
                steps: [],
                tableSteps: [
                    BreakStep(action: "Neck", detail: "Side bend + gentle rotation, both sides", duration: "15s / side"),
                    BreakStep(action: "Chest", detail: "Hands clasped behind back or doorway", duration: "20s"),
                    BreakStep(action: "Mid-back", detail: "Reach up, slight lean — thoracic", duration: "15s"),
                    BreakStep(action: "Hip flexors", detail: "Standing stretch, both sides", duration: "15s / side"),
                    BreakStep(action: "Wrists", detail: "Prayer + reverse prayer, or finger fans", duration: "15s"),
                ],
                durationHint: "About 2 minutes",
                testMode: testMode,
                symbolName: "figure.stand",
                intervalMinutes: 40,
                reason: "Mobility break — undo desk stiffness"
            )
        case "C":
            return BreakModel(
                layer: "C",
                title: "Resistance Band Circuit",
                subtitle: "Every 90 minutes",
                steps: [],
                tableSteps: [
                    BreakStep(action: "Pull-aparts", detail: "Arms long, squeeze shoulder blades", duration: "×12"),
                    BreakStep(action: "Face pulls", detail: "Elbows high, external rotation", duration: "×10"),
                    BreakStep(action: "Rows", detail: "Quiet ribs, squeeze mid-back", duration: "×10"),
                    BreakStep(action: "Hinge / bridge", detail: "Band good-mornings or glute bridges", duration: "×10"),
                    BreakStep(action: "Hip abductions", detail: "Optional — standing, both sides", duration: "×8 / side"),
                ],
                durationHint: "About 4 minutes",
                testMode: testMode,
                symbolName: "dumbbell.fill",
                intervalMinutes: 90,
                reason: "Strength reset — posture muscles + blood flow"
            )
        default:
            return BreakModel(
                layer: "A",
                title: "Eyes + Posture Reset",
                subtitle: "Every 20 minutes",
                steps: [],
                tableSteps: [
                    BreakStep(action: "Gaze", detail: "Look ~20 ft / 6 m away — soft focus", duration: "20s"),
                    BreakStep(action: "Blink", detail: "Full blinks — close completely, open soft", duration: "×10"),
                    BreakStep(action: "Chin tuck", detail: "Gentle double-chin, drop shoulders", duration: "5s"),
                    BreakStep(action: "Scap squeeze", detail: "Pinch shoulder blades, then release", duration: "×5"),
                ],
                durationHint: "About 40 seconds",
                testMode: testMode,
                symbolName: "eye",
                intervalMinutes: 20,
                reason: "Eye strain + static posture reset"
            )
        }
    }

    static func testSequence() -> [BreakModel] {
        ["A", "B", "C"].map { builtin(layer: $0, testMode: true) }
    }

    static func load(from path: String) throws -> BreakModel {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder().decode(BreakModel.self, from: data)
    }

    init(
        layer: String,
        title: String,
        subtitle: String,
        steps: [String],
        tableSteps: [BreakStep],
        durationHint: String,
        testMode: Bool,
        symbolName: String,
        intervalMinutes: Int,
        reason: String
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
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        layer = try c.decodeIfPresent(String.self, forKey: .layer) ?? "A"
        let fallback = BreakModel.builtin(layer: layer, testMode: false)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? fallback.title
        subtitle = try c.decodeIfPresent(String.self, forKey: .subtitle) ?? fallback.subtitle
        steps = try c.decodeIfPresent([String].self, forKey: .steps) ?? []
        tableSteps = try c.decodeIfPresent([BreakStep].self, forKey: .tableSteps) ?? []
        if tableSteps.isEmpty && steps.isEmpty {
            tableSteps = fallback.tableSteps
        }
        durationHint = try c.decodeIfPresent(String.self, forKey: .durationHint) ?? fallback.durationHint
        testMode = try c.decodeIfPresent(Bool.self, forKey: .testMode) ?? false
        symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? fallback.symbolName
        intervalMinutes = try c.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? fallback.intervalMinutes
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? fallback.reason
    }

    var cadenceLabel: String {
        if intervalMinutes >= 60 {
            let h = intervalMinutes / 60
            let m = intervalMinutes % 60
            if m == 0 { return h == 1 ? "Every hour" : "Every \(h) hours" }
            return "Every \(intervalMinutes) minutes"
        }
        return "Every \(intervalMinutes) minutes"
    }

    var windowLabel: String {
        "\(intervalMinutes)-minute window"
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
