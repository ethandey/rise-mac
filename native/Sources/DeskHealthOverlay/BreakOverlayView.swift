import SwiftUI

/// Break sheet — scannable steps; theme follows ThemeManager (organic macOS).
struct BreakOverlayView: View {
    let model: BreakModel
    var primaryTitle: String = "Done"
    var stepLabel: String = ""
    let onAction: (BreakAction) -> Void

    @ObservedObject private var theme = ThemeManager.shared

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
        .background { sheetBackground }
        .preferredColorScheme(theme.colorScheme)
    }

    private var sheetBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.regularMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(theme.sheetFill.opacity(theme.isDark ? 1 : 0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(theme.sheetStroke, lineWidth: 0.5)
            }
            .shadow(color: theme.sheetShadow, radius: theme.isDark ? 40 : 28, y: theme.isDark ? 20 : 12)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)

                if !model.durationHint.isEmpty {
                    Text(model.durationHint)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            if !stepLabel.isEmpty {
                Text(stepLabel)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(theme.textTertiary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.chipFill))
            }
        }
    }

    private var stepsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.displayRows.enumerated()), id: \.offset) { index, row in
                stepRow(index: index + 1, row: row)
                if index < model.displayRows.count - 1 {
                    Rectangle()
                        .fill(theme.hairline)
                        .frame(height: 1)
                        .padding(.leading, 36)
                }
            }
        }
    }

    private func stepRow(index: Int, row: BreakStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(theme.chipText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.chipFill))

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.action)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    if !row.duration.isEmpty && row.duration != "—" {
                        Text(row.duration)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(theme.textPrimary)
                            .monospacedDigit()
                    }
                }
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(theme.textCue)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Snooze 5 min") { onAction(.snooze(minutes: 5)) }
                .buttonStyle(ThemedSecondaryButtonStyle())

            Spacer(minLength: 8)

            Button(primaryTitle) { onAction(.done) }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ThemedPrimaryButtonStyle())
        }
    }
}

// MARK: - Themed buttons

struct ThemedPrimaryButtonStyle: ButtonStyle {
    @ObservedObject private var theme = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        ThemedPrimaryButton(configuration: configuration, theme: theme)
    }

    private struct ThemedPrimaryButton: View {
        let configuration: ButtonStyle.Configuration
        @ObservedObject var theme: ThemeManager
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.primaryButtonText.opacity(configuration.isPressed ? 0.75 : 1))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(fill)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.02 : 1))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            let base = theme.primaryButtonFill
            if configuration.isPressed { return base.opacity(0.85) }
            if hovering { return base.opacity(0.92) }
            return base
        }
    }
}

struct ThemedSecondaryButtonStyle: ButtonStyle {
    @ObservedObject private var theme = ThemeManager.shared

    func makeBody(configuration: Configuration) -> some View {
        ThemedSecondaryButton(configuration: configuration, theme: theme)
    }

    private struct ThemedSecondaryButton: View {
        let configuration: ButtonStyle.Configuration
        @ObservedObject var theme: ThemeManager
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondaryButtonText.opacity(configuration.isPressed ? 0.7 : 1))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(theme.secondaryButtonFill.opacity(hovering || configuration.isPressed ? 1.4 : 1))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(theme.secondaryButtonBorder, lineWidth: 1)
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.02 : 1))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .onHover { hovering = $0 }
        }
    }
}
