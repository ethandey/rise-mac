import AppKit

/// Menu bar: icon only; dropdown shows notify time + time left, location, theme.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var app: AppDelegate?
    private var refreshTimer: Timer?

    private let scheduler = RoutineScheduler.shared
    private let theme = ThemeManager.shared
    private let location = LocationManager.shared

    func install(app: AppDelegate) {
        self.app = app
        // Square length = icon only (no countdown title in the bar)
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.title = ""
            if let image = NSImage(
                systemSymbolName: "figure.mind.and.body",
                accessibilityDescription: "Rise"
            ) {
                image.isTemplate = true
                button.image = image
            }
            button.toolTip = "Rise"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item

        rebuildMenu()
        updateTooltip()

        location.onStatusChange = { [weak self] in
            self?.updateTooltip()
            self?.rebuildMenu()
        }

        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateTooltip()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func refresh() {
        updateTooltip()
        rebuildMenu()
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func updateTooltip() {
        guard let button = statusItem?.button else { return }
        // Icon-only bar; put the next notify summary in the tooltip
        if let idle = scheduler.idleReason {
            button.toolTip = "Rise · \(idle)"
            return
        }
        let layer = scheduler.nextLayer
        let at = scheduler.formatNotifyTime(scheduler.nextDue(for: layer))
        let left = scheduler.formatCountdown(scheduler.secondsUntil(layer: layer))
        button.toolTip = "Rise · \(scheduler.layerTitle(layer)) at \(at) · in \(left)"
    }

    // MARK: - Menu

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        addDisabled(menu, "Rise")
        menu.addItem(.separator())

        // Notify schedule: when + time left
        addDisabled(menu, "Upcoming")
        addNotifyRow(menu, layer: "A", label: "Eyes")
        addNotifyRow(menu, layer: "B", label: "Stretch")
        addNotifyRow(menu, layer: "C", label: "Bands")

        if let idle = scheduler.idleReason {
            addDisabled(menu, idle)
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

        // Location / home geofence
        addDisabled(menu, "Location")
        addDisabled(menu, location.status.menuLabel)
        if location.homeSet {
            if location.status == .away {
                addDisabled(menu, "Alerts pause while away")
            } else if location.status == .atHome {
                addDisabled(menu, "Alerts on at home")
            }
            _ = add(menu, "Clear Home", #selector(clearHome))
        } else {
            _ = add(menu, "Set Home Here…", #selector(setHome))
        }

        menu.addItem(.separator())

        // Appearance
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

    /// e.g. "Eyes  ·  2:34 PM  ·  in 12:34"
    private func addNotifyRow(_ menu: NSMenu, layer: String, label: String) {
        let dueDate = scheduler.nextDue(for: layer)
        let at = scheduler.formatNotifyTime(dueDate)
        let sec = scheduler.secondsUntil(layer: layer)
        let left = sec <= 0 ? "now" : "in \(scheduler.formatCountdown(sec))"
        let title = "\(label)  ·  \(at)  ·  \(left)"
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if layer == scheduler.nextLayer, scheduler.idleReason == nil {
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

    @objc private func setHome() {
        // Immediate feedback in menu while Core Location runs
        rebuildMenu()
        updateTooltip()
        location.setHomeHere()
        rebuildMenu()
        updateTooltip()
    }

    @objc private func clearHome() {
        location.clearHome()
        rebuildMenu()
        updateTooltip()
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
