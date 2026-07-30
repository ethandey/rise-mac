import AppKit
import SwiftUI

/// Application host: menu bar, routine scheduler, overlay presentation.
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
                // System theme changed — refresh if mode is Automatic
                ThemeManager.shared.objectWillChange.send()
                self?.menuBar.refresh()
            }
        }

        switch mode {
        case .menuBar(let auto):
            menuBar.install(app: self)
            wireScheduler()
            scheduler.start()
            if let auto, !auto.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.startSequence(auto, oneShot: false)
                }
            }

        case .oneShot(let models):
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
            guard let self, !self.isPresenting else { return }
            let model = BreakModel.builtin(layer: layer, testMode: false)
            self.startSequence([model], oneShot: false)
        }
    }

    /// Start a break sequence (single layer or multi).
    func startSequence(_ models: [BreakModel], oneShot: Bool) {
        guard presenter.phase == .idle else { return }
        self.oneShot = oneShot
        applyAppAppearance()
        menuBar.refresh()

        let primaryLayer = models.first?.layer.uppercased() ?? "A"

        presenter.present(models: models) { [weak self] action in
            guard let self else { return }
            self.lastStdoutAction = action
            fputs(action.stdoutToken + "\n", stdout)
            fflush(stdout)

            switch action {
            case .done:
                self.scheduler.markCompleted(layer: primaryLayer)
            case .snooze(let minutes):
                self.scheduler.snooze(minutes: minutes)
                SystemControl.run("snooze", "\(minutes)")
            case .skip:
                // Still advance so we don't re-fire immediately
                self.scheduler.markCompleted(layer: primaryLayer)
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
