import AppKit

/// Menu bar status item for managing Desk Health.
@MainActor
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?
    private weak var app: AppDelegate?

    func install(app: AppDelegate) {
        self.app = app
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = NSImage(
                systemSymbolName: "figure.mind.and.body",
                accessibilityDescription: "Rise"
            ) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Rise"
            }
            button.toolTip = "Rise"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    func refresh() {
        statusItem?.menu = buildMenu()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let title = NSMenuItem(title: "Rise", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())

        let busy = app?.isPresenting == true

        let a = add(menu, "Start Eyes + Posture", #selector(startA))
        a.isEnabled = !busy
        let b = add(menu, "Start Stand + Stretch", #selector(startB))
        b.isEnabled = !busy
        let c = add(menu, "Start Band Circuit", #selector(startC))
        c.isEnabled = !busy

        return menu
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
}
