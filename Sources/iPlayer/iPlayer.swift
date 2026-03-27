import AppKit
import CFFmpeg

@main
struct iPlayerApp {
    static func main() {
        let version = avcodec_version()
        let major = version >> 16
        let minor = (version >> 8) & 0xFF
        let micro = version & 0xFF
        print("iPlayer - FFmpeg avcodec \(major).\(minor).\(micro)")

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    var window: NSWindow!
    var playerController: PlayerController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()

        let contentRect = NSRect(x: 0, y: 0, width: 960, height: 540)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "iPlayer"
        window.center()
        window.minSize = NSSize(width: 480, height: 320)
        window.isReleasedWhenClosed = false

        playerController = PlayerController()
        let playerView = PlayerView(controller: playerController)
        window.contentView = playerView
        window.makeKeyAndOrderFront(nil)
        window.acceptsMouseMovedEvents = true

        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        playerController.openFile(path: filename)
        return true
    }

    @MainActor private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "iPlayer 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "iPlayer 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "파일")
        fileMenu.addItem(withTitle: "열기...", action: #selector(openFileAction(_:)), keyEquivalent: "o")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        NSApp.mainMenu = mainMenu
    }

    @MainActor @objc func openFileAction(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            playerController.openFile(path: url.path)
        }
    }
}
