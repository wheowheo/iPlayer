import AppKit
import CFFmpeg
import UniformTypeIdentifiers

@main
struct iPlayerApp {
    static func main() {
        let version = avcodec_version()
        let major = version >> 16
        let minor = (version >> 8) & 0xFF
        let micro = version & 0xFF
        fputs("iPlayer - FFmpeg avcodec \(major).\(minor).\(micro)\n", stderr)

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, @unchecked Sendable {
    var window: NSWindow!
    var playerController: PlayerController!
    private var videoAspectRatio: CGFloat = 16.0 / 9.0

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
        window.delegate = self
        window.aspectRatio = NSSize(width: 16, height: 9)

        playerController = PlayerController()
        playerController.onMediaInfo = { [weak self] info in
            guard let self = self, info.displayWidth > 0 && info.displayHeight > 0 else { return }
            let ratio = CGFloat(info.displayWidth) / CGFloat(info.displayHeight)
            self.videoAspectRatio = ratio
            DispatchQueue.main.async {
                self.window.aspectRatio = NSSize(width: ratio, height: 1.0)
                // 세로 영상이면 창 크기를 세로로 맞춤
                if info.rotation == 90 || info.rotation == 270 {
                    let screenHeight = self.window.screen?.visibleFrame.height ?? 800
                    let newHeight = min(CGFloat(info.displayHeight), screenHeight * 0.8)
                    let newWidth = newHeight * ratio
                    self.window.setContentSize(NSSize(width: newWidth, height: newHeight))
                    self.window.center()
                }
                self.window.title = "iPlayer - \(URL(fileURLWithPath: self.playerController.filePath).lastPathComponent)"
            }
        }

        let playerView = PlayerView(controller: playerController)
        window.contentView = playerView
        window.makeKeyAndOrderFront(nil)
        window.acceptsMouseMovedEvents = true

        NSApp.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments
        if args.count > 1 {
            let path = args[1]
            playerController.openFile(path: path)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard let pc = playerController else { return false }
        pc.openFile(path: filename)
        return true
    }

    @MainActor private func setupMenu() {
        let mainMenu = NSMenu()

        // App 메뉴
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "iPlayer 정보", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "iPlayer 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 파일 메뉴
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "파일")
        fileMenu.addItem(withTitle: "열기...", action: #selector(openFileAction(_:)), keyEquivalent: "o")
        fileMenu.addItem(withTitle: "자막 열기...", action: #selector(openSubtitleAction(_:)), keyEquivalent: "")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // 재생 메뉴
        let playMenuItem = NSMenuItem()
        let playMenu = NSMenu(title: "재생")
        playMenu.addItem(withTitle: "재생/일시정지", action: #selector(togglePlayAction(_:)), keyEquivalent: " ")
        playMenu.addItem(withTitle: "정지", action: #selector(stopAction(_:)), keyEquivalent: "")
        playMenu.addItem(NSMenuItem.separator())
        playMenu.addItem(withTitle: "전체화면", action: #selector(toggleFullScreenAction(_:)), keyEquivalent: "f")
        playMenu.items.last?.keyEquivalentModifierMask = .command
        playMenuItem.submenu = playMenu
        mainMenu.addItem(playMenuItem)

        // 윈도우 메뉴
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

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

    @MainActor @objc func openSubtitleAction(_ sender: Any) {
        let panel = NSOpenPanel()
        panel.allowsOtherFileTypes = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            playerController.loadSubtitle(path: url.path)
        }
    }

    @objc func togglePlayAction(_ sender: Any) {
        playerController?.togglePlayPause()
    }

    @objc func stopAction(_ sender: Any) {
        playerController?.stop()
    }

    @MainActor @objc func toggleFullScreenAction(_ sender: Any) {
        window?.toggleFullScreen(nil)
    }
}
