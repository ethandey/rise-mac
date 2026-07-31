import AppKit
import SwiftUI

/// Application host: menu bar, routine scheduler, soft eyes + firm overlays.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mode: LaunchMode
    private let presenter = OverlayPresenter()
    private let menuBar = MenuBarController()
    private let scheduler = RoutineScheduler.shared
    private var oneShot = false
    private var lastStdoutAction: BreakAction?
    private var appearanceObserver: NSObjectProtocol?

    var isPresenting: Bool { presenter.phase != .idle }
    var schedulerRef: RoutineScheduler { scheduler }

    init(mode: LaunchMode) {
        self.mode = mode
        if case .oneShot = mode { oneShot = true }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        applyAppAppearance()

        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                ThemeManager.shared.objectWillChange.send()
                self?.menuBar.refresh()
            }
        }

        switch mode {
        case .menuBar(let auto):
            menuBar.install(app: self)
            wireScheduler()
            // Activity monitor starts with scheduler — firm grace after launch
            scheduler.start()
            if let auto, !auto.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.startSequence(auto, oneShot: false)
                }
            }

        case .oneShot(let models):
            // One-shot: no grace delay — user asked for it
            ActivityMonitor.shared.clearFirmDefer()
            startSequence(models, oneShot: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        scheduler.stop()
        if let appearanceObserver {
            DistributedNotificationCenter.default().removeObserver(appearanceObserver)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func applyAppAppearance() {
        NSApp.appearance = ThemeManager.shared.nsAppearance
    }

    private func wireScheduler() {
        scheduler.onLayerDue = { [weak self] layer in
            guard let self else { return false }
            if self.isPresenting {
                fputs("rise: layer \(layer) due but busy — retry\n", stderr)
                return false
            }
            let venue = self.scheduler.breakVenue
            fputs(
                "rise: scheduled \(layer) pos=\(self.scheduler.deskPosition.rawValue) venue=\(venue.rawValue)\n",
                stderr
            )
            let model = BreakModel.builtin(
                layer: layer,
                position: self.scheduler.deskPosition,
                testMode: false,
                venue: venue
            )
            self.startSequence([model], oneShot: false)
            return true
        }
    }

    func startSequence(_ models: [BreakModel], oneShot: Bool) {
        guard presenter.phase == .idle else { return }
        self.oneShot = oneShot
        applyAppAppearance()
        menuBar.refresh()

        let primaryLayer = models.first?.layer.uppercased() ?? "A"
        let venue = scheduler.breakVenue
        // Re-resolve against current posture / venue if single layer
        let resolved: [BreakModel]
        if models.count == 1, let layer = models.first?.layer {
            resolved = [
                BreakModel.builtin(
                    layer: layer,
                    position: scheduler.deskPosition,
                    testMode: models[0].testMode,
                    venue: venue
                )
            ]
        } else {
            resolved = models
        }

        presenter.present(models: resolved) { [weak self] action in
            guard let self else { return }
            self.lastStdoutAction = action
            fputs(action.stdoutToken + "\n", stdout)
            fflush(stdout)

            switch action {
            case .done:
                self.scheduler.markCompleted(layer: primaryLayer, action: .done)
            case .snooze(let minutes):
                self.scheduler.snooze(minutes: minutes)
            case .skip:
                self.scheduler.markCompleted(layer: primaryLayer, action: .skip)
            }

            self.menuBar.refresh()

            if self.oneShot {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    func appearanceDidChange() {
        applyAppAppearance()
        menuBar.refresh()
    }
}
