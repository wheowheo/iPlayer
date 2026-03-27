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
    private var recentFilesMenu: NSMenu!

    // 최근 파일 목록 (UserDefaults)
    private let recentFilesKey = "iPlayer.recentFiles"
    private let maxRecentFiles = 10

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
                if info.rotation == 90 || info.rotation == 270 {
                    let screenHeight = self.window.screen?.visibleFrame.height ?? 800
                    let newHeight = min(CGFloat(info.displayHeight), screenHeight * 0.8)
                    let newWidth = newHeight * ratio
                    self.window.setContentSize(NSSize(width: newWidth, height: newHeight))
                    self.window.center()
                }
                let name = URL(fileURLWithPath: self.playerController.filePath).lastPathComponent
                self.window.title = "iPlayer - \(name)"
                // 최근 파일에 추가
                self.addRecentFile(self.playerController.filePath)
            }
        }

        let playerView = PlayerView(controller: playerController)
        window.contentView = playerView
        window.makeKeyAndOrderFront(nil)
        window.acceptsMouseMovedEvents = true

        NSApp.activate(ignoringOtherApps: true)

        let args = CommandLine.arguments
        if args.count > 1 {
            playerController.openFile(path: args[1])
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

    // MARK: - 메뉴

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
        fileMenu.addItem(NSMenuItem.separator())

        // 최근 파일 서브메뉴
        let recentItem = NSMenuItem(title: "최근 파일", action: nil, keyEquivalent: "")
        recentFilesMenu = NSMenu(title: "최근 파일")
        recentItem.submenu = recentFilesMenu
        fileMenu.addItem(recentItem)
        updateRecentFilesMenu()

        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(withTitle: "최근 파일 지우기", action: #selector(clearRecentFiles(_:)), keyEquivalent: "")
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

        // 트랙 메뉴
        let trackMenuItem = NSMenuItem()
        let trackMenu = NSMenu(title: "트랙")
        trackMenu.delegate = self
        trackMenuItem.submenu = trackMenu
        mainMenu.addItem(trackMenuItem)

        // 윈도우 메뉴
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "윈도우")
        windowMenu.addItem(withTitle: "최소화", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - 액션

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

    @objc func openRecentFile(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        playerController?.openFile(path: path)
    }

    @objc func clearRecentFiles(_ sender: Any) {
        UserDefaults.standard.removeObject(forKey: recentFilesKey)
        updateRecentFilesMenu()
    }

    @objc func selectAudioTrack(_ sender: NSMenuItem) {
        let idx = Int32(sender.tag)
        playerController?.selectAudioTrack(index: idx)
    }

    // MARK: - 최근 파일

    private func addRecentFile(_ path: String) {
        var recent = UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? []
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        if recent.count > maxRecentFiles {
            recent = Array(recent.prefix(maxRecentFiles))
        }
        UserDefaults.standard.set(recent, forKey: recentFilesKey)
        updateRecentFilesMenu()
    }

    private func updateRecentFilesMenu() {
        guard let menu = recentFilesMenu else { return }
        menu.removeAllItems()
        let recent = UserDefaults.standard.stringArray(forKey: recentFilesKey) ?? []
        if recent.isEmpty {
            let emptyItem = NSMenuItem(title: "(없음)", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for path in recent {
                let name = URL(fileURLWithPath: path).lastPathComponent
                let item = NSMenuItem(title: name, action: #selector(openRecentFile(_:)), keyEquivalent: "")
                item.representedObject = path
                item.target = self
                menu.addItem(item)
            }
        }
    }
}

// MARK: - 트랙 메뉴 동적 생성
extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "트랙" else { return }
        menu.removeAllItems()

        guard let pc = playerController else { return }

        // 오디오 트랙
        if !pc.demuxer.audioStreams.isEmpty {
            let header = NSMenuItem(title: "오디오 트랙", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for (i, audio) in pc.demuxer.audioStreams.enumerated() {
                let title = "  \(i + 1). \(audio.stream.codecName) \(audio.sampleRate)Hz \(audio.channels)ch"
                let item = NSMenuItem(title: title, action: #selector(selectAudioTrack(_:)), keyEquivalent: "")
                item.tag = Int(audio.stream.index)
                item.target = self
                if audio.stream.index == pc.demuxer.selectedAudioIndex {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        // 자막 트랙 (내장)
        if !pc.demuxer.subtitleStreams.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "내장 자막", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for (i, sub) in pc.demuxer.subtitleStreams.enumerated() {
                let title = "  \(i + 1). \(sub.codecName)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if sub.index == pc.demuxer.selectedSubtitleIndex {
                    item.state = .on
                }
                menu.addItem(item)
            }
        }

        // 외부 자막
        if !pc.subtitles.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let subItem = NSMenuItem(title: "외부 자막 로드됨 (\(pc.subtitles.count)개 항목)", action: nil, keyEquivalent: "")
            subItem.isEnabled = false
            menu.addItem(subItem)
        }

        if menu.items.isEmpty {
            let noTrack = NSMenuItem(title: "(트랙 없음)", action: nil, keyEquivalent: "")
            noTrack.isEnabled = false
            menu.addItem(noTrack)
        }
    }
}
