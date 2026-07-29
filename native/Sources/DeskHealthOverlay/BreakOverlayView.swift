import SwiftUI

/// OLED break sheet — scannable step list (not a literal table).
/// Layout: number · title · time on one line; cue underneath.
struct BreakOverlayView: View {
    let model: BreakModel
    var primaryTitle: String = "Done"
    var stepLabel: String = ""
    let onAction: (BreakAction) -> Void

    private let surface = Color(red: 0.04, green: 0.04, blue: 0.045)
    private let chip = Color(red: 0.12, green: 0.12, blue: 0.125)
    private let textPrimary = Color.white
    private let textSecondary = Color.white.opacity(0.48)
    private let textCue = Color.white.opacity(0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            stepsList
                .padding(.top, 16)
            actions
                .padding(.top, 20)
        }
        .padding(22)
        .frame(width: 400)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.8), radius: 40, y: 20)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(textPrimary)

                if !model.durationHint.isEmpty {
                    Text(model.durationHint)
                        .font(.system(size: 12))
                        .foregroundStyle(textSecondary)
                }
            }
            Spacer(minLength: 8)
            if !stepLabel.isEmpty {
                Text(stepLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.06)))
            }
        }
    }

    // MARK: - Steps (easy scan: #  Title  time  /  cue)

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.displayRows.enumerated()), id: \.offset) { index, row in
                stepRow(index: index + 1, row: row)

                if index < model.displayRows.count - 1 {
                    // Light hairline — not a full table grid
                    Rectangle()
                        .fill(Color.white.opacity(0.05))
                        .frame(height: 1)
                        .padding(.leading, 36)
                }
            }
        }
    }

    private func stepRow(index: Int, row: BreakStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // Index — monochrome chip
            Text("\(index)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Circle().fill(chip))

            // Title + cue
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.action)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(textPrimary)
                        .lineLimit(1)

                    Spacer(minLength: 6)

                    // Time / reps — same white as title for readability
                    if !row.duration.isEmpty && row.duration != "—" {
                        Text(row.duration)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(textPrimary)
                            .monospacedDigit()
                    }
                }

                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(textCue)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Skip") { onAction(.skip) }
                .keyboardShortcut(.escape, modifiers: [])
                .buttonStyle(OLEDSecondaryButtonStyle())

            Button("Snooze") { onAction(.snooze(minutes: 5)) }
                .buttonStyle(OLEDSecondaryButtonStyle())

            Spacer(minLength: 8)

            Button(primaryTitle) { onAction(.done) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(OLEDPrimaryButtonStyle())
        }
    }
}

// MARK: - Buttons

struct OLEDPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OLEDPrimaryButton(configuration: configuration)
    }

    private struct OLEDPrimaryButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        private let idle = Color.white
        private let hover = Color(white: 0.92)
        private let press = Color(white: 0.78)

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.02 : 1))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return press }
            if hovering { return hover }
            return idle
        }
    }
}

struct OLEDSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OLEDSecondaryButton(configuration: configuration)
    }

    private struct OLEDSecondaryButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(labelOpacity))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(fillOpacity))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 1)
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.02 : 1))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var fillOpacity: Double {
            configuration.isPressed || hovering ? 0.12 : 0.0
        }

        private var borderOpacity: Double {
            if configuration.isPressed { return 0.22 }
            if hovering { return 0.26 }
            return 0.14
        }

        private var labelOpacity: Double {
            if configuration.isPressed { return 0.70 }
            if hovering { return 1.0 }
            return 0.78
        }
    }
}
