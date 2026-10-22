import SwiftUI
import AppKit
import SysObsCore

/// SysObs — sysobs in the menu bar. Bundle id com.redjay.sysobs, LSUIElement (no Dock icon); build.sh wraps the
/// binary into ~/Applications/SysObs.app. Standard macOS, the DeskHub / Teams Watch look: a plain menu under an
/// NSStatusItem (autosave name "sysobs") and a Settings scene with tabs.
@main
struct SysObsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView().environment(delegate.model)
        }
    }
}

/// The status item is made here, not by a MenuBarExtra, so it can carry its autosave name (its place in the bar is
/// remembered across launches). The menu is SwiftUI (MenuView) hosted in an NSHostingMenu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem?
    private var observers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "sysobs"
        item.behavior = []
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: "sysobs")
            button.image?.isTemplate = true
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        item.menu = NSHostingMenu(rootView: MenuView().environment(model))
        statusItem = item
        model.onRefresh = { [weak self] in self?.updateLabel() }
        model.start()
        updateLabel()

        // Cmd+Tab (Teams Watch's rule): while a window (Settings) is open the app is a regular app, in the switcher
        // and the Dock with its icon; when the last window closes it is menu-bar-only again (.accessory).
        let nc = NotificationCenter.default
        // both observers run on the main queue (queue: .main), so the main-actor work is assumed, not hopped to
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let w = n.object as? NSWindow, Self.counts(w) else { return }
                self?.setPolicy(.regular)
            }
        })
        observers.append(nc.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] n in
            let closing = n.object as? NSWindow
            DispatchQueue.main.async {
                let open = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.counts($0) }
                if !open { self?.setPolicy(.accessory) }
            }
        })
    }

    /// The label beside the symbol: the one-minute load of the latest sample, nothing until there is one.
    private func updateLabel() {
        guard let button = statusItem?.button else { return }
        button.title = model.labelText
        button.toolTip = model.tooltipText
    }

    /// A real window: titled, on the normal level. The status item's menu and panels do not count.
    private static func counts(_ w: NSWindow) -> Bool {
        w.styleMask.contains(.titled) && w.level == .normal && !(w is NSPanel)
    }

    private func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    /// Launching the app again while it runs (Finder, `open -a SysObs`, the Dock icon) opens Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        OpenSettings.now()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
}

/// The Settings scene opened from AppKit (the status item's menu is outside any SwiftUI scene, so the
/// `openSettings` environment action is not there): the responder-chain action SwiftUI installs for it.
enum OpenSettings {
    @MainActor static func now() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
