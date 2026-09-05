import SwiftUI
import AppKit

/// AppKit owns the single-window lifecycle; SwiftUI owns its content.
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        installMenus()
        let content = RootView().environmentObject(model)
            .frame(minWidth: 1000, minHeight: 720)
            .preferredColorScheme(.light)
            .task {
                await model.start()
                // Practice-only capture of our view, not the desktop or other apps.
                if model.demo, let flag = CommandLine.arguments.firstIndex(of: "--snapshot"),
                   CommandLine.arguments.indices.contains(flag + 1) {
                    try? await Task.sleep(for: .seconds(2))
                    self.capture(to: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
                }
            }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Payday"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1000, height: 720)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        window.center()
        self.window = window
        showWindow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }

    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func paycheck() { if model?.busy == false { model?.page = .paycheck } }
    @objc private func defaults() { if model?.busy == false { model?.page = .defaults } }
    @objc private func history() { if model?.busy == false { model?.page = .history } }
    @objc private func refresh() { model?.refresh() }

    private func capture(to url: URL) {
        guard let view = window?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: url, options: .atomic) }
    }

    private func installMenus() {
        let bar = NSMenu()
        NSApp.mainMenu = bar
        func menu(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: title); item.submenu = submenu; bar.addItem(item)
            return submenu
        }
        func add(_ title: String, to menu: NSMenu, action: Selector, key: String = "", target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target; menu.addItem(item)
        }
        let app = menu("Payday")
        add("About Payday", to: app, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        app.addItem(.separator())
        add("Hide Payday", to: app, action: #selector(NSApplication.hide(_:)), key: "h")
        app.addItem(.separator())
        add("Quit Payday", to: app, action: #selector(NSApplication.terminate(_:)), key: "q")
        let file = menu("File")
        add("Show Payday", to: file, action: #selector(showWindow), key: "0", target: self)
        add("Close", to: file, action: #selector(NSWindow.performClose(_:)), key: "w")
        let edit = menu("Edit")
        add("Undo", to: edit, action: Selector(("undo:")), key: "z")
        add("Redo", to: edit, action: Selector(("redo:")), key: "Z")
        edit.addItem(.separator())
        add("Cut", to: edit, action: #selector(NSText.cut(_:)), key: "x")
        add("Copy", to: edit, action: #selector(NSText.copy(_:)), key: "c")
        add("Paste", to: edit, action: #selector(NSText.paste(_:)), key: "v")
        add("Select All", to: edit, action: #selector(NSText.selectAll(_:)), key: "a")
        let view = menu("View")
        add("Paycheck", to: view, action: #selector(paycheck), key: "1", target: self)
        add("Defaults", to: view, action: #selector(defaults), key: "2", target: self)
        add("History", to: view, action: #selector(history), key: "3", target: self)
        view.addItem(.separator())
        add("Refresh YNAB", to: view, action: #selector(refresh), key: "r", target: self)
        let windows = menu("Window")
        NSApp.windowsMenu = windows
        add("Minimize", to: windows, action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add("Zoom", to: windows, action: #selector(NSWindow.performZoom(_:)))
    }
}

@main enum PaydayMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
