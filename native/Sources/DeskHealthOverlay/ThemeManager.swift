import AppKit
import SwiftUI

/// System-native appearance for Rise — organic macOS (liquid glass / Tahoe-adjacent).
@MainActor
final class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    enum Mode: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var menuTitle: String {
            switch self {
            case .system: return "Automatic"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    @Published private(set) var mode: Mode {
        didSet { persist(); objectWillChange.send() }
    }

    private let defaultsKey = "rise.appearance.mode"

    private init() {
        if let raw = UserDefaults.standard.string(forKey: defaultsKey),
           let m = Mode(rawValue: raw) {
            mode = m
        } else {
            mode = .system
        }
    }

    func setMode(_ mode: Mode) {
        guard self.mode != mode else { return }
        self.mode = mode
    }

    private func persist() {
        UserDefaults.standard.set(mode.rawValue, forKey: defaultsKey)
    }

    /// Resolved dark/light for painting UI.
    var isDark: Bool {
        switch mode {
        case .dark: return true
        case .light: return false
        case .system:
            let app = NSApp.effectiveAppearance
            let match = app.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua
        }
    }

    var colorScheme: ColorScheme {
        isDark ? .dark : .light
    }

    var nsAppearance: NSAppearance? {
        switch mode {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    // MARK: - Semantic colors (organic, system-feeling)

    var dimOverlay: Color {
        isDark
            ? Color.black.opacity(0.88)
            : Color(red: 0.92, green: 0.93, blue: 0.95).opacity(0.55)
    }

    /// Soft sky wash in light mode so dim isn't pure white plate.
    var dimWash: Color {
        isDark
            ? Color.clear
            : Color(red: 0.78, green: 0.84, blue: 0.92).opacity(0.35)
    }

    var sheetFill: Color {
        isDark
            ? Color(red: 0.04, green: 0.04, blue: 0.045)
            : Color.white.opacity(0.78)
    }

    var sheetStroke: Color {
        isDark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.06)
    }

    var sheetShadow: Color {
        isDark
            ? Color.black.opacity(0.75)
            : Color.black.opacity(0.12)
    }

    var textPrimary: Color {
        isDark ? .white : Color(red: 0.11, green: 0.11, blue: 0.12)
    }

    var textSecondary: Color {
        isDark ? Color.white.opacity(0.48) : Color.black.opacity(0.45)
    }

    var textTertiary: Color {
        isDark ? Color.white.opacity(0.38) : Color.black.opacity(0.35)
    }

    var textCue: Color {
        isDark ? Color.white.opacity(0.72) : Color.black.opacity(0.58)
    }

    var chipFill: Color {
        isDark ? Color(red: 0.12, green: 0.12, blue: 0.125) : Color.black.opacity(0.05)
    }

    var chipText: Color {
        isDark ? Color.white.opacity(0.85) : Color.black.opacity(0.75)
    }

    var hairline: Color {
        isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }

    var primaryButtonFill: Color {
        isDark ? .white : Color(red: 0.12, green: 0.12, blue: 0.14)
    }

    var primaryButtonText: Color {
        isDark ? .black : .white
    }

    var secondaryButtonBorder: Color {
        isDark ? Color.white.opacity(0.16) : Color.black.opacity(0.12)
    }

    var secondaryButtonFill: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)
    }

    var secondaryButtonText: Color {
        isDark ? Color.white.opacity(0.88) : Color.black.opacity(0.78)
    }

    var rewardCircleFill: Color {
        isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.04)
    }
}
