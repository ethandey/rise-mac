import AppKit

/// Menu bar: live countdowns, start layers, organic appearance switcher.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var app: AppDelegate?
    private var refreshTimer: Timer?

    private let scheduler = RoutineScheduler.shared
    private let theme = ThemeManager.shared

    func install(app: AppDelegate) {
        self.app = app
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.imagePosition = .imageLeading
            if let image = NSImage(
                systemSymbolName: "figure.mind.and.body",
                accessibilityDescription: "Rise"
            ) {
                image.isTemplate = true
                button.image = image
            }
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.toolTip = "Rise"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        rebuildMenu()
        updateStatusTitle()

        // Live countdown in the bar + menu rebuild when opened
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateStatusTitle()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func refresh() {
        updateStatusTitle()
        rebuildMenu()
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    // MARK: - Status title

    private func updateStatusTitle() {
        guard let button = statusItem?.button else { return }
        let text = " \(scheduler.statusBarTitle)"
        button.title = text
    }

    // MARK: - Menu

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        // Header
        addDisabled(menu, "Rise")
        menu.addItem(.separator())

        // Live countdowns
        addDisabled(menu, "Next breaks")
        addCountdownRow(menu, layer: "A", label: "Eyes")
        addCountdownRow(menu, layer: "B", label: "Stretch")
        addCountdownRow(menu, layer: "C", label: "Bands")

        if let until = scheduler.snoozeUntil, until > scheduler.now {
            let left = scheduler.formatCountdown(until.timeIntervalSince(scheduler.now))
            addDisabled(menu, "Snoozed · \(left)")
        }

        menu.addItem(.separator())

        let busy = app?.isPresenting == true
        let a = add(menu, "Start Eyes + Posture", #selector(startA))
        a.isEnabled = !busy
        let b = add(menu, "Start Stand + Stretch", #selector(startB))
        b.isEnabled = !busy
        let c = add(menu, "Start Band Circuit", #selector(startC))
        c.isEnabled = !busy

        menu.addItem(.separator())

        // Appearance — feels like a system Settings control
        let appearance = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "Appearance")
        for mode in ThemeManager.Mode.allCases {
            let item = NSMenuItem(
                title: mode.menuTitle,
                action: #selector(setAppearance(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.state = theme.mode == mode ? .on : .off
            sub.addItem(item)
        }
        appearance.submenu = sub
        menu.addItem(appearance)
    }

    private func addCountdownRow(_ menu: NSMenu, layer: String, label: String) {
        let sec = scheduler.secondsUntil(layer: layer)
        let time = scheduler.formatCountdown(sec)
        let due = sec <= 0 ? "due" : time
        let title = "\(label)  ·  \(due)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        // Emphasize the next one slightly via attributed title
        if layer == scheduler.nextLayer {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.menuBarFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor
            ]
            item.attributedTitle = NSAttributedString(string: "→ \(title)", attributes: attrs)
        }
        menu.addItem(item)
    }

    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    @discardableResult
    private func add(
        _ menu: NSMenu,
        _ title: String,
        _ sel: Selector,
        _ key: String = ""
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func startA() {
        app?.startSequence([BreakModel.builtin(layer: "A", testMode: false)], oneShot: false)
    }

    @objc private func startB() {
        app?.startSequence([BreakModel.builtin(layer: "B", testMode: false)], oneShot: false)
    }

    @objc private func startC() {
        app?.startSequence([BreakModel.builtin(layer: "C", testMode: false)], oneShot: false)
    }

    @objc private func setAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ThemeManager.Mode(rawValue: raw) else { return }
        theme.setMode(mode)
        NSApp.appearance = theme.nsAppearance
        app?.appearanceDidChange()
        rebuildMenu()
    }
}
