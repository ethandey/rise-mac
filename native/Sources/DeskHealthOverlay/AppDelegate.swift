import AppKit
import SwiftUI

/// Application host: menu bar manager + overlay presentation.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let mode: LaunchMode
    private let presenter = OverlayPresenter()
    private let menuBar = MenuBarController()
    private var oneShot = false
    private var lastStdoutAction: BreakAction?

    var isPresenting: Bool { presenter.phase != .idle }

    init(mode: LaunchMode) {
        self.mode = mode
        if case .oneShot = mode { oneShot = true }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        switch mode {
        case .menuBar(let auto):
            menuBar.install(app: self)
            if let auto, !auto.isEmpty {
                // Slight delay so menu bar is up first
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    self?.startSequence(auto, oneShot: false)
                }
            }

        case .oneShot(let models):
            startSequence(models, oneShot: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu bar app has no windows when idle — never auto-quit from that.
        false
    }

    /// Start a break sequence (single layer or A→B→C).
    func startSequence(_ models: [BreakModel], oneShot: Bool) {
        guard presenter.phase == .idle else { return }
        self.oneShot = oneShot
        menuBar.refresh()

        presenter.present(models: models) { [weak self] action in
            guard let self else { return }
            self.lastStdoutAction = action
            // Always print for CLI consumers (done | skip | snooze:N)
            fputs(action.stdoutToken + "\n", stdout)
            fflush(stdout)

            // Honor delay minutes into Python state when possible
            if case .snooze(let minutes) = action {
                SystemControl.run("snooze", "\(minutes)")
            }

            self.menuBar.refresh()

            if self.oneShot {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
