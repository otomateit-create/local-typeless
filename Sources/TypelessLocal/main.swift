import AppKit

setvbuf(stdout, nil, _IONBF, 0)

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let dictationKeyMonitor = DictationKeyMonitor()
    private let controller = DictationController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "mic.circle", accessibilityDescription: "TypelessLocal")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "TypelessLocal", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        statusItem = item

        Permissions.auditAndRequest()

        let controller = self.controller
        dictationKeyMonitor.onToggle = {
            MainActor.assumeIsolated {
                controller.toggle()
            }
        }
        dictationKeyMonitor.start()
    }
}

// `delegate` est une globale : NSApplication.delegate étant une référence
// faible, il faut le retenir ici pour qu'il ne soit pas libéré.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.delegate = delegate
    app.run()
}
