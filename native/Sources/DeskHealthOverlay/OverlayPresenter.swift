import AppKit
import SwiftUI

/// Orchestrates pre-warning → slow OLED fade-in → multi-layer break sheet.
@MainActor
final class OverlayPresenter: ObservableObject {
    enum Phase: Equatable {
        case idle
        case warning
        case presenting
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var warningProgress: Double = 0
    /// Whole seconds left on the warning countdown.
    @Published private(set) var warningSecondsLeft: Int = 0
    /// Drives soft enter/exit of the warning card.
    @Published private(set) var warningCardVisible: Bool = false
    @Published private(set) var dimOpacity: Double = 0
    @Published private(set) var sheetOpacity: Double = 0
    @Published private(set) var sheetOffset: CGFloat = 12
    @Published private(set) var sheetScale: CGFloat = 1
    /// Subtle completion reward after Done.
    @Published private(set) var showReward: Bool = false
    @Published private(set) var rewardAppeared: Bool = false
    @Published private(set) var models: [BreakModel] = []
    @Published private(set) var index: Int = 0

    var currentModel: BreakModel? {
        guard models.indices.contains(index) else { return nil }
        return models[index]
    }

    var isSequence: Bool { models.count > 1 }
    var isLast: Bool { index >= models.count - 1 }
    var stepLabel: String {
        guard isSequence else { return "" }
        return "\(index + 1) of \(models.count)"
    }

    var primaryTitle: String {
        if isSequence && !isLast { return "Next" }
        return "Done"
    }

    // MARK: Warning copy (why this popup is here)

    /// Headline on the pill.
    var warningHeadline: String {
        if isSequence {
            return "Break sequence starting"
        }
        return currentModel.map { "\($0.title) starting" } ?? "Break starting"
    }

    /// Why the break fired.
    var warningReason: String {
        if isSequence {
            return "Test walkthrough · eyes → stretch → bands"
        }
        return currentModel?.reason ?? "Scheduled movement break"
    }

    /// Cadence line shown on the pill (single phrase, no doubled time).
    var warningCadenceLine: String {
        if isSequence {
            return "Layers A · B · C"
        }
        return currentModel?.cadenceLabel ?? ""
    }

    private var windows: [NSWindow] = []
    private var warningWindow: NSWindow?
    private var onComplete: ((BreakAction) -> Void)?
    private var finished = false
    private var timers: [Timer] = []
    private var warningStart: Date?

    // Timing — longer notice so it isn’t jarring
    private let warningDuration: TimeInterval = 10.0
    private let dimFadeDuration: TimeInterval = 1.35
    private let sheetFadeDelay: TimeInterval = 0.55
    private let sheetFadeDuration: TimeInterval = 0.85

    func present(models: [BreakModel], onComplete: @escaping (BreakAction) -> Void) {
        guard phase == .idle, !models.isEmpty else { return }
        self.models = models
        self.index = 0
        self.onComplete = onComplete
        self.finished = false
        self.dimOpacity = 0
        self.sheetOpacity = 0
        self.sheetOffset = 14
        self.sheetScale = 1
        self.showReward = false
        self.rewardAppeared = false
        self.warningProgress = 0
        self.warningSecondsLeft = Int(warningDuration.rounded())
        self.warningCardVisible = false

        beginWarning()
    }

    func cancelAll() {
        invalidateTimers()
        tearDownWindows()
        phase = .idle
    }

    // MARK: - User actions from sheet

    func handle(_ action: BreakAction) {
        switch action {
        case .done:
            if isSequence && !isLast {
                advanceLayer()
            } else {
                finish(.done)
            }
        case .skip:
            if isSequence && !isLast {
                advanceLayer()
            } else {
                finish(.skip)
            }
        case .snooze:
            finish(action)
        }
    }

    /// Delay from the warning pill — soft exit, then snooze.
    func delayFromWarning(minutes: Int) {
        guard phase == .warning, !finished else { return }
        dismissWarningGracefully(action: .snooze(minutes: minutes))
    }

    // MARK: - Warning

    private func beginWarning() {
        phase = .warning
        showWarningPill()
        warningStart = Date()

        // Soft enter after the window is up
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.55)) {
                self.warningCardVisible = true
            }
        }

        let start = Date()
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] t in
            Task { @MainActor in
                guard let self else { t.invalidate(); return }
                guard self.phase == .warning, !self.finished else { t.invalidate(); return }
                let elapsed = Date().timeIntervalSince(start)
                let remaining = max(0, self.warningDuration - elapsed)
                self.warningProgress = min(1, elapsed / self.warningDuration)
                self.warningSecondsLeft = Int(ceil(remaining))
                if elapsed >= self.warningDuration {
                    t.invalidate()
                    self.transitionToOverlay()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers.append(timer)
    }

    /// Fade the pill out, then complete (used by Delay).
    private func dismissWarningGracefully(action: BreakAction) {
        guard phase == .warning, !finished else { return }
        finished = true
        invalidateTimers()

        withAnimation(.easeIn(duration: 0.45)) {
            warningCardVisible = false
        }

        // Also ease the NSWindow alpha so nothing pops off
        if let win = warningWindow {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.45
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                win.animator().alphaValue = 0
            }
        }

        let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.tearDownWindows()
                self.phase = .idle
                let cb = self.onComplete
                self.onComplete = nil
                cb?(action)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func showWarningPill() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let root = WarningPillView(presenter: self)
        let hosting = NSHostingView(rootView: root)
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        // Mask hosting view so AppKit never paints square corners under the card
        hosting.layer?.cornerRadius = 16
        hosting.layer?.masksToBounds = true
        hosting.layer?.cornerCurve = .continuous

        // Extra room so SwiftUI soft-shadow isn't clipped by the window
        let size = NSSize(width: 440, height: 148)
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - 12
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.isOpaque = false
        window.backgroundColor = .clear
        // Window-level shadow is always rectangular — use SwiftUI shadow only
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        warningWindow = window
    }

    // MARK: - Full overlay

    private func transitionToOverlay() {
        guard phase == .warning, !finished else { return }

        // Softly tuck the warning away before the full dim
        withAnimation(.easeIn(duration: 0.35)) {
            warningCardVisible = false
        }
        if let win = warningWindow {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                win.animator().alphaValue = 0
            }
        }

        let handoff = Timer.scheduledTimer(withTimeInterval: 0.38, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.phase == .warning, !self.finished else { return }
                self.warningWindow?.orderOut(nil)
                self.warningWindow?.close()
                self.warningWindow = nil
                self.phase = .presenting
                self.buildOverlayWindows()
                NSApp.activate(ignoringOtherApps: true)

                withAnimation(.easeInOut(duration: self.dimFadeDuration)) {
                    self.dimOpacity = 1
                }

                let sheetTimer = Timer.scheduledTimer(withTimeInterval: self.sheetFadeDelay, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        withAnimation(.easeOut(duration: self?.sheetFadeDuration ?? 0.85)) {
                            self?.sheetOpacity = 1
                            self?.sheetOffset = 0
                        }
                    }
                }
                RunLoop.main.add(sheetTimer, forMode: .common)
                self.timers.append(sheetTimer)
            }
        }
        RunLoop.main.add(handoff, forMode: .common)
        timers.append(handoff)
    }

    private func buildOverlayWindows() {
        tearDownOverlayOnly()
        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens

        for (i, screen) in screens.enumerated() {
            let isPrimary = (screen == NSScreen.main) || (i == 0 && NSScreen.main == nil)
            let root: AnyView
            if isPrimary {
                root = AnyView(OverlayRootView(presenter: self).focusable())
            } else {
                root = AnyView(SecondaryOLEDView(presenter: self))
            }

            let hosting = NSHostingView(rootView: root)
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless, .fullSizeContentView],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.contentView = hosting
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
            window.collectionBehavior = [
                .canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary
            ]
            window.ignoresMouseEvents = !isPrimary
            window.acceptsMouseMovedEvents = isPrimary
            window.isReleasedWhenClosed = false
            window.alphaValue = 1
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
            if isPrimary {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }

    private func advanceLayer() {
        withAnimation(.easeIn(duration: 0.25)) {
            sheetOpacity = 0
            sheetOffset = 8
        }
        let t = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.index = min(self.index + 1, self.models.count - 1)
                withAnimation(.easeOut(duration: 0.55)) {
                    self.sheetOpacity = 1
                    self.sheetOffset = 0
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
    }

    private func finish(_ action: BreakAction) {
        guard !finished else { return }
        // Warning dismiss always goes through the soft path
        if phase == .warning {
            dismissWarningGracefully(action: action)
            return
        }

        finished = true
        invalidateTimers()

        if action == .done {
            playDoneRewardThenExit(action: action)
        } else {
            playSoftExit(action: action)
        }
    }

    /// Done: brief monochrome reward, then staged fade of sheet → dim → close.
    private func playDoneRewardThenExit(action: BreakAction) {
        // Haptic tick (trackpad / Force Touch when available)
        NSHapticFeedbackManager.defaultPerformer.perform(
            .levelChange,
            performanceTime: .now
        )

        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            showReward = true
            rewardAppeared = true
            sheetScale = 1.02
        }

        // Hold the reward beat, then ease out
        let hold = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.easeInOut(duration: 0.55)) {
                    self.sheetOpacity = 0
                    self.sheetOffset = 10
                    self.sheetScale = 0.96
                }

                let dimStart = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        guard let self else { return }
                        withAnimation(.easeInOut(duration: 0.75)) {
                            self.dimOpacity = 0
                        }
                        self.fadeOverlayWindows(duration: 0.75)

                        let done = Timer.scheduledTimer(withTimeInterval: 0.85, repeats: false) { [weak self] _ in
                            Task { @MainActor in
                                self?.completeSession(action: action)
                            }
                        }
                        RunLoop.main.add(done, forMode: .common)
                        self.timers.append(done)
                    }
                }
                RunLoop.main.add(dimStart, forMode: .common)
                self.timers.append(dimStart)
            }
        }
        RunLoop.main.add(hold, forMode: .common)
        timers.append(hold)
    }

    /// Skip / snooze: smooth staged exit, no reward.
    private func playSoftExit(action: BreakAction) {
        withAnimation(.easeInOut(duration: 0.4)) {
            sheetOpacity = 0
            sheetOffset = 12
            sheetScale = 0.98
        }

        let dimStart = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                withAnimation(.easeInOut(duration: 0.65)) {
                    self.dimOpacity = 0
                }
                self.fadeOverlayWindows(duration: 0.65)

                let done = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.completeSession(action: action)
                    }
                }
                RunLoop.main.add(done, forMode: .common)
                self.timers.append(done)
            }
        }
        RunLoop.main.add(dimStart, forMode: .common)
        timers.append(dimStart)
    }

    private func fadeOverlayWindows(duration: TimeInterval) {
        for win in windows {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                win.animator().alphaValue = 0
            }
        }
    }

    private func completeSession(action: BreakAction) {
        tearDownWindows()
        phase = .idle
        showReward = false
        rewardAppeared = false
        sheetScale = 1
        let cb = onComplete
        onComplete = nil
        cb?(action)
    }

    private func invalidateTimers() {
        timers.forEach { $0.invalidate() }
        timers.removeAll()
    }

    private func tearDownOverlayOnly() {
        windows.forEach { $0.orderOut(nil); $0.close() }
        windows.removeAll()
    }

    private func tearDownWindows() {
        warningWindow?.orderOut(nil)
        warningWindow?.close()
        warningWindow = nil
        tearDownOverlayOnly()
    }
}

// MARK: - Root views

struct OverlayRootView: View {
    @ObservedObject var presenter: OverlayPresenter

    var body: some View {
        ZStack {
            Color.black
                .opacity(presenter.dimOpacity)
                .ignoresSafeArea()

            if let model = presenter.currentModel {
                Group {
                    if presenter.showReward {
                        CompletionRewardView(appeared: presenter.rewardAppeared)
                    } else {
                        BreakOverlayView(
                            model: model,
                            primaryTitle: presenter.primaryTitle,
                            stepLabel: presenter.stepLabel,
                            onAction: { presenter.handle($0) }
                        )
                    }
                }
                .opacity(presenter.sheetOpacity)
                .offset(y: presenter.sheetOffset)
                .scaleEffect(presenter.sheetScale)
            }
        }
        .preferredColorScheme(.dark)
        .onExitCommand {
            // Don't skip during reward beat
            if !presenter.showReward {
                presenter.handle(.skip)
            }
        }
    }
}

/// Brief monochrome reward after tapping Done.
struct CompletionRewardView: View {
    var appeared: Bool

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 64, height: 64)
                Circle()
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    .frame(width: 64, height: 64)
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .scaleEffect(appeared ? 1 : 0.6)
                    .opacity(appeared ? 1 : 0)
            }

            VStack(spacing: 4) {
                Text("Nice work")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Break complete")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 6)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 32)
        .frame(minWidth: 240)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(red: 0.04, green: 0.04, blue: 0.045))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.75), radius: 36, y: 16)
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: appeared)
    }
}

struct SecondaryOLEDView: View {
    @ObservedObject var presenter: OverlayPresenter

    var body: some View {
        Color.black
            .opacity(presenter.dimOpacity)
            .ignoresSafeArea()
            .preferredColorScheme(.dark)
    }
}

// MARK: - Pre-warning pill (reason + window + delay)

struct WarningPillView: View {
    @ObservedObject var presenter: OverlayPresenter

    private let corner: CGFloat = 16
    private let cardFill = Color(red: 0.06, green: 0.06, blue: 0.065)

    var body: some View {
        ZStack {
            Color.clear
            card
                .opacity(presenter.warningCardVisible ? 1 : 0)
                .offset(y: presenter.warningCardVisible ? 0 : -12)
                .scaleEffect(presenter.warningCardVisible ? 1 : 0.97)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.45), value: presenter.warningCardVisible)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 2.5)
                        .frame(width: 30, height: 30)
                    Circle()
                        .trim(from: 0, to: presenter.warningProgress)
                        .stroke(Color.white.opacity(0.92), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .frame(width: 30, height: 30)
                        .rotationEffect(.degrees(-90))
                    Text("\(presenter.warningSecondsLeft)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                        .monospacedDigit()
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(presenter.warningHeadline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if !presenter.warningCadenceLine.isEmpty {
                        Text(presenter.warningCadenceLine)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.42))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)

                Button("Delay 10 min") {
                    presenter.delayFromWarning(minutes: 10)
                }
                .buttonStyle(WarningGhostButtonStyle())

                Button("Delay 5 min") {
                    presenter.delayFromWarning(minutes: 5)
                }
                .buttonStyle(WarningSolidButtonStyle())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 408)
        .background(cardFill)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .compositingGroup()
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
    }
}

// MARK: - Warning pill button styles (monochrome, with hover)

/// Primary delay — solid white on OLED
struct WarningSolidButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WarningSolidButton(configuration: configuration)
    }

    private struct WarningSolidButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.black.opacity(configuration.isPressed ? 0.7 : 1))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(fill)
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.03 : 1))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var fill: Color {
            if configuration.isPressed { return Color(white: 0.78) }
            if hovering { return Color(white: 0.94) }
            return .white
        }
    }
}

/// Secondary delay — outlined ghost
struct WarningGhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WarningGhostButton(configuration: configuration)
    }

    private struct WarningGhostButton: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.white.opacity(labelOpacity))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(fillOpacity))
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 1)
                        )
                )
                .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.03 : 1))
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
                .onHover { hovering = $0 }
        }

        private var fillOpacity: Double {
            if configuration.isPressed { return 0.14 }
            if hovering { return 0.12 }
            return 0.0
        }

        private var borderOpacity: Double {
            if configuration.isPressed { return 0.28 }
            if hovering { return 0.32 }
            return 0.18
        }

        private var labelOpacity: Double {
            if configuration.isPressed { return 0.7 }
            if hovering { return 1.0 }
            return 0.82
        }
    }
}


