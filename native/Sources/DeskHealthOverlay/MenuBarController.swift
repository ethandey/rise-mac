import AppKit

/// Icon-only menu: modes with gray times, desk, location, appearance.
/// Toggles re-open the menu so it doesn’t vanish after each click.
/// While open, mode countdowns tick live every second (in-place title updates).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private weak var app: AppDelegate?
    private var refreshTimer: Timer?
    /// When true, re-open menu after the current action finishes.
    private var shouldKeepMenuOpen = false
    private var menuIsOpen = false
    /// Mode rows keyed by layer — updated live without rebuilding the whole menu.
    private var modeItems: [String: NSMenuItem] = [:]
    private var modeNames: [String: String] = [:]
    private weak var locationStatusItem: NSMenuItem?
    private weak var postureItem: NSMenuItem?
    private weak var nextSummaryItem: NSMenuItem?

    private let scheduler = RoutineScheduler.shared
    private let theme = ThemeManager.shared
    private let location = LocationManager.shared

    func install(app: AppDelegate) {
        self.app = app
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
        // Keep menu alive while we refresh titles; default autoenables is fine
        menu.autoenablesItems = false
        item.menu = menu
        statusItem = item

        location.onStatusChange = { [weak self] in
            self?.updateTooltip()
            if self?.menuIsOpen == true {
                self?.rebuildMenu()
            }
        }

        rebuildMenu()
        updateTooltip()

        // Tooltip always; open menu countdowns every second
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.updateTooltip()
                if self.menuIsOpen {
                    self.refreshLiveCountdowns()
                }
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
        shouldKeepMenuOpen = false
        menuIsOpen = true
        rebuildMenu()
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Re-open after toggle-style actions so the menu stays “open”
        if shouldKeepMenuOpen {
            shouldKeepMenuOpen = false
            DispatchQueue.main.async { [weak self] in
                self?.reopenMenu()
            }
        }
    }

    /// Call from actions that should not dismiss the menu permanently.
    private func keepMenuOpen() {
        shouldKeepMenuOpen = true
        rebuildMenu()
        updateTooltip()
    }

    private func reopenMenu() {
        guard let button = statusItem?.button else { return }
        // performClick re-opens the status item menu
        button.performClick(nil)
    }

    private func updateTooltip() {
        guard let button = statusItem?.button else { return }
        if let idle = scheduler.idleReason {
            button.toolTip = "Rise · \(idle)"
            return
        }
        let layer = scheduler.nextLayer
        let at = scheduler.formatNotifyTime(scheduler.nextDue(for: layer))
        let left = scheduler.formatCountdown(scheduler.secondsUntil(layer: layer))
        let pos = scheduler.hasStandingDeskEffective
            ? " · \(scheduler.deskPosition == .standing ? "Standing" : "Sitting")"
            : ""
        button.toolTip = "Rise\(pos) · \(scheduler.layerTitle(layer)) at \(at) · in \(left)"
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        modeItems.removeAll()
        modeNames.removeAll()
        locationStatusItem = nil
        postureItem = nil
        nextSummaryItem = nil

        // —— Title ——
        addDisabled(menu, "Rise")
        menu.addItem(.separator())

        // —— Status (next break + where you are) ——
        let summary = NSMenuItem(title: nextSummaryTitle(), action: nil, keyEquivalent: "")
        summary.isEnabled = false
        menu.addItem(summary)
        nextSummaryItem = summary

        let locItem = NSMenuItem(title: currentLocationTitle(), action: nil, keyEquivalent: "")
        locItem.isEnabled = false
        menu.addItem(locItem)
        locationStatusItem = locItem

        menu.addItem(.separator())

        // —— Modes ——
        let cafe = scheduler.isCafeMode
        addDisabled(menu, cafe ? "Modes · café" : "Modes")
        let busy = app?.isPresenting == true
        addModeRow(menu, name: "Eyes", layer: "A", action: #selector(startA), enabled: !busy)
        addModeRow(
            menu,
            name: cafe ? "Café reset" : "Change + Move",
            layer: "B",
            action: #selector(startB),
            enabled: !busy
        )
        if !cafe, scheduler.hasStandingDeskEffective {
            let sName = scheduler.deskPosition == .standing
                ? "Switch to Sitting"
                : "Switch to Standing"
            addModeRow(menu, name: sName, layer: "S", action: #selector(startS), enabled: !busy)
        }
        addModeRow(
            menu,
            name: cafe ? "Café move" : "Walk",
            layer: "C",
            action: #selector(startC),
            enabled: !busy
        )

        // Posture under modes when standing desk applies at current place
        scheduler.syncStandingDeskFromLocation()
        if !cafe, scheduler.hasStandingDeskEffective {
            menu.addItem(.separator())
            addDisabled(menu, "Desk now")
            let sit = NSMenuItem(title: "Now sitting", action: #selector(markSitting), keyEquivalent: "")
            sit.target = self
            sit.isEnabled = true
            sit.state = scheduler.deskPosition == .sitting ? .on : .off
            menu.addItem(sit)
            let stand = NSMenuItem(title: "Now standing", action: #selector(markStanding), keyEquivalent: "")
            stand.target = self
            stand.isEnabled = true
            stand.state = scheduler.deskPosition == .standing ? .on : .off
            menu.addItem(stand)
            let posture = NSMenuItem(
                title: "In posture \(scheduler.minutesInPosition) min",
                action: nil,
                keyEquivalent: ""
            )
            posture.isEnabled = false
            menu.addItem(posture)
            postureItem = posture
        }

        // —— Home (own section) ——
        menu.addItem(.separator())
        addDisabled(menu, "Home")
        if location.homeSet, let addr = location.homeAddress, !addr.isEmpty {
            let short = addr.count > 48 ? String(addr.prefix(45)) + "…" : addr
            addDisabled(menu, short)
        } else if location.homeSet {
            addDisabled(menu, "Pin set")
        } else {
            addDisabled(menu, "Not set")
        }
        let homeStand = NSMenuItem(
            title: "Standing desk",
            action: #selector(toggleHomeStanding),
            keyEquivalent: ""
        )
        homeStand.target = self
        homeStand.isEnabled = true
        homeStand.state = location.homeHasStandingDesk ? .on : .off
        menu.addItem(homeStand)
        addAction(menu, "Set Home Here", #selector(setHome))

        // —— Office (own section) ——
        menu.addItem(.separator())
        addDisabled(menu, "Office")
        if location.officeSet, let addr = location.officeAddress, !addr.isEmpty {
            let short = addr.count > 48 ? String(addr.prefix(45)) + "…" : addr
            addDisabled(menu, short)
        } else if location.officeSet {
            addDisabled(menu, "Pin set")
        } else {
            addDisabled(menu, "Not set")
        }
        let officeStand = NSMenuItem(
            title: "Standing desk",
            action: #selector(toggleOfficeStanding),
            keyEquivalent: ""
        )
        officeStand.target = self
        officeStand.isEnabled = true
        officeStand.state = location.officeHasStandingDesk ? .on : .off
        menu.addItem(officeStand)
        addAction(menu, "Set Office Here", #selector(setOffice))

        if case .denied = location.status {
            menu.addItem(.separator())
            addDisabled(menu, "Enable Location for Rise in System Settings")
        }

        // —— Appearance ——
        menu.addItem(.separator())
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
            item.isEnabled = true
            sub.addItem(item)
        }
        appearance.submenu = sub
        appearance.isEnabled = true
        menu.addItem(appearance)
    }

    /// Top bar + location status tick live; mode rows only when minutes change.
    private func refreshLiveCountdowns() {
        nextSummaryItem?.title = nextSummaryTitle()
        locationStatusItem?.title = currentLocationTitle()
        if let postureItem {
            postureItem.title = "In posture \(scheduler.minutesInPosition) min"
        }
        for (layer, item) in modeItems {
            let name = modeNames[layer] ?? layer
            let next = modeRowAttributed(name: name, layer: layer)
            if item.attributedTitle?.string != next.string {
                item.attributedTitle = next
            }
        }
    }

    private func nextSummaryTitle() -> String {
        if let idle = scheduler.idleReason {
            // Don't bury next-up under keyboard presence — only real schedule blocks
            let layer = scheduler.nextLayer
            let left = scheduler.formatCountdown(scheduler.secondsUntil(layer: layer))
            // Skip pure activity presence in the Next line (location has its own row)
            if idle.hasPrefix("At keyboard") || idle.hasPrefix("Passive")
                || idle.hasPrefix("Away ·") || idle.hasPrefix("Away from") {
                // fall through to normal next
            } else {
                return "Next  ·  \(scheduler.layerTitle(layer))  ·  \(left) left  ·  \(idle)"
            }
        }
        let layer = scheduler.nextLayer
        let sec = scheduler.secondsUntil(layer: layer)
        if sec <= 0 {
            return "Next  ·  \(scheduler.layerTitle(layer))  ·  due now"
        }
        let at = scheduler.formatNotifyTime(scheduler.nextDue(for: layer))
        let left = scheduler.formatCountdown(sec)
        return "Next  ·  \(scheduler.layerTitle(layer))  ·  \(left)  ·  ~\(at)"
    }

    /// Where you are right now (under Next, after Rise title).
    private func currentLocationTitle() -> String {
        switch location.status {
        case .atHome: return "Location  ·  At home"
        case .atOffice: return "Location  ·  At office"
        case .away: return "Location  ·  Away · café mode"
        case .locating: return "Location  ·  Locating…"
        case .denied: return "Location  ·  Denied"
        case .noneSet: return "Location  ·  No places set"
        case .error(let m): return "Location  ·  \(m)"
        }
    }

    /// Clickable mode: name + fire time + active minutes (no second countdown).
    private func addModeRow(
        _ menu: NSMenu,
        name: String,
        layer: String,
        action: Selector,
        enabled: Bool
    ) {
        let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = layer
        item.attributedTitle = modeRowAttributed(name: name, layer: layer)
        item.isEnabled = enabled
        menu.addItem(item)
        modeItems[layer] = item
        modeNames[layer] = name
    }

    private func modeRowAttributed(name: String, layer: String) -> NSAttributedString {
        let sec = scheduler.secondsUntil(layer: layer)
        let at = scheduler.formatNotifyTime(scheduler.nextDue(for: layer))
        let mins = scheduler.formatMinutesLeft(layer: layer)
        // “~3:15 PM · 18 min” — clock estimate if you stay active + active minutes left
        let meta: String
        if sec <= 0 {
            meta = "  ·  due now"
        } else {
            meta = "  ·  ~\(at)  ·  \(mins)"
        }

        let font = NSFont.menuFont(ofSize: 0)
        let line = NSMutableAttributedString()
        if layer == scheduler.nextLayer {
            line.append(
                NSAttributedString(
                    string: "→ ",
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.labelColor,
                    ]
                )
            )
        }
        line.append(
            NSAttributedString(
                string: name,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.labelColor,
                ]
            )
        )
        line.append(
            NSAttributedString(
                string: meta,
                attributes: [
                    .font: font,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        )
        return line
    }

    private func addDisabled(_ menu: NSMenu, _ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ menu: NSMenu, _ title: String, _ sel: Selector) {
        let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    // MARK: - Actions
    // Modes that open an overlay: let menu close naturally.
    // Toggles / settings: keep menu open.

    @objc private func startA() {
        app?.startSequence([
            BreakModel.builtin(
                layer: "A",
                position: scheduler.deskPosition,
                venue: scheduler.breakVenue
            )
        ], oneShot: false)
    }

    @objc private func startB() {
        app?.startSequence([
            BreakModel.builtin(
                layer: "B",
                position: scheduler.deskPosition,
                venue: scheduler.breakVenue
            )
        ], oneShot: false)
    }

    @objc private func startC() {
        app?.startSequence([
            BreakModel.builtin(
                layer: "C",
                position: scheduler.deskPosition,
                venue: scheduler.breakVenue
            )
        ], oneShot: false)
    }

    @objc private func startS() {
        app?.startSequence([
            BreakModel.builtin(
                layer: "S",
                position: scheduler.deskPosition,
                venue: scheduler.breakVenue
            )
        ], oneShot: false)
    }

    @objc private func toggleHomeStanding() {
        location.setStandingDesk(for: .home, enabled: !location.homeHasStandingDesk)
        scheduler.syncStandingDeskFromLocation()
        keepMenuOpen()
    }

    @objc private func toggleOfficeStanding() {
        location.setStandingDesk(for: .office, enabled: !location.officeHasStandingDesk)
        scheduler.syncStandingDeskFromLocation()
        keepMenuOpen()
    }

    @objc private func markSitting() {
        scheduler.setDeskPosition(.sitting)
        keepMenuOpen()
    }

    @objc private func markStanding() {
        scheduler.setDeskPosition(.standing)
        keepMenuOpen()
    }

    @objc private func setHome() {
        // Always pin to current location (replaces previous home pin)
        location.setHomeHere()
        keepMenuOpen()
    }

    @objc private func setOffice() {
        // Always pin to current location (replaces previous office pin)
        location.setOfficeHere()
        keepMenuOpen()
    }

    @objc private func setAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ThemeManager.Mode(rawValue: raw) else { return }
        theme.setMode(mode)
        NSApp.appearance = theme.nsAppearance
        app?.appearanceDidChange()
        keepMenuOpen()
    }
}
