import AppKit
import CFFmpeg
import UniformTypeIdentifiers

@main
struct iPlayerApp {
    static func main() {
        fputs("iPlayer \(Version.full)\n", stderr)
        let codecVer = avcodec_version()
        fputs("FFmpeg avcodec \(codecVer >> 16).\((codecVer >> 8) & 0xFF).\(codecVer & 0xFF)\n", stderr)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)  // 독립 앱으로 인식 → 포커스 수신 가능
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

        playerController = PlayerController()
        playerController.onMediaInfo = { [weak self] info in
            // 이미 main.async에서 호출됨 — 바로 실행
            guard let self = self, info.displayWidth > 0 && info.displayHeight > 0 else { return }
            let ratio = CGFloat(info.displayWidth) / CGFloat(info.displayHeight)
            self.videoAspectRatio = ratio

            let screen = self.window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
            let maxW = screen.width * 0.8
            let maxH = screen.height * 0.8

            var newWidth: CGFloat
            var newHeight: CGFloat

            if ratio >= 1.0 {
                newWidth = min(CGFloat(info.displayWidth), maxW)
                newHeight = newWidth / ratio
                if newHeight > maxH {
                    newHeight = maxH
                    newWidth = newHeight * ratio
                }
            } else {
                newHeight = min(CGFloat(info.displayHeight), maxH)
                newWidth = newHeight * ratio
                if newWidth > maxW {
                    newWidth = maxW
                    newHeight = newWidth / ratio
                }
            }

            if ratio >= 1.0 {
                self.window.minSize = NSSize(width: 480, height: 480 / ratio)
            } else {
                self.window.minSize = NSSize(width: 320 * ratio, height: 320)
            }
            self.window.setContentSize(NSSize(width: newWidth, height: newHeight))
            self.window.aspectRatio = NSSize(width: ratio, height: 1.0)
            self.window.center()

            let name = URL(fileURLWithPath: self.playerController.filePath).lastPathComponent
            self.window.title = "iPlayer - \(name)"
            self.addRecentFile(self.playerController.filePath)
        }

        let playerView = PlayerView(controller: playerController)
        window.contentView = playerView
        window.makeKeyAndOrderFront(nil)
        window.acceptsMouseMovedEvents = true

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(window.contentView)

        let args = CommandLine.arguments
        let isBench = args.contains("--bench")
        let benchDuration: Double = 15.0
        let files = args.dropFirst().filter { !$0.hasPrefix("--") }

        if isBench && !files.isEmpty {
            playerController.dropDebugger.isEnabled = true
            playerController.openFile(path: files.first!)

            let pc = playerController!
            let file = files.first!
            let actualDuration = min(benchDuration, pc.duration - 1.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + max(actualDuration, 3.0)) {
                let name = URL(fileURLWithPath: file).lastPathComponent
                pc.dropDebugger.printReport(
                    file: name,
                    renderMode: pc.renderMode.rawValue,
                    renderedFrames: pc.renderedFrames,
                    droppedFrames: pc.droppedFrames
                )
                NSApp.terminate(nil)
            }
        } else if !files.isEmpty {
            playerController.openFile(path: files.first!)
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
        appMenu.addItem(withTitle: "iPlayer 정보", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "라이브러리 정보", action: #selector(showLibraryInfo(_:)), keyEquivalent: "")
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

    @MainActor @objc func showAbout(_ sender: Any) {
        let codecVer = avcodec_version()
        let ffmpegStr = "\(codecVer >> 16).\((codecVer >> 8) & 0xFF).\(codecVer & 0xFF)"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "iPlayer",
            .applicationVersion: Version.short,
            .version: "\(Version.full)  (FFmpeg \(ffmpegStr))",
        ])
    }

    @MainActor @objc func showLibraryInfo(_ sender: Any) {
        func ver(_ v: UInt32) -> String { "\(v >> 16).\((v >> 8) & 0xFF).\(v & 0xFF)" }

        // FFmpeg 런타임 버전 조회
        let ffmpegVersions: [String: String] = [
            "avcodec": ver(avcodec_version()),
            "avformat": ver(avformat_version()),
            "avutil": ver(avutil_version()),
            "swscale": ver(swscale_version()),
            "swresample": ver(swresample_version()),
        ]

        // Package.swift에서 linkedLibrary / linkedFramework 자동 파싱
        let (linkedLibs, linkedFrameworks) = Self.parsePackageSwift()

        var text = "FFmpeg 8.1 (정적 링크, LGPL 2.1+)\n"
        text += String(repeating: "─", count: 50) + "\n\n"

        for lib in linkedLibs {
            if let version = ffmpegVersions[lib] {
                text += "  lib\(lib)  \(version)\n"
            } else {
                text += "  \(lib)\n"
            }
        }

        text += "\n\nmacOS 시스템 프레임워크\n"
        text += String(repeating: "─", count: 50) + "\n\n"

        for fw in linkedFrameworks {
            text += "  \(fw)\n"
        }

        let alert = NSAlert()
        alert.messageText = "라이브러리 의존성"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 300))
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.string = text
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        alert.accessoryView = scrollView
        alert.informativeText = ""

        alert.runModal()
    }

    /// Package.swift를 파싱하여 linkedLibrary, linkedFramework 목록을 반환
    private static func parsePackageSwift() -> (libs: [String], frameworks: [String]) {
        let source = URL(fileURLWithPath: #filePath)
        let projectRoot = source
            .deletingLastPathComponent() // iPlayer/
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // project root
        let packageURL = projectRoot.appendingPathComponent("Package.swift")

        guard let content = try? String(contentsOf: packageURL, encoding: .utf8) else {
            return ([], [])
        }

        var libs: [String] = []
        var frameworks: [String] = []

        // .linkedLibrary("name") 패턴
        let libPattern = try! NSRegularExpression(pattern: #"\.linkedLibrary\("([^"]+)"\)"#)
        let fwPattern = try! NSRegularExpression(pattern: #"\.linkedFramework\("([^"]+)"\)"#)
        let range = NSRange(content.startIndex..., in: content)

        for match in libPattern.matches(in: content, range: range) {
            if let r = Range(match.range(at: 1), in: content) {
                libs.append(String(content[r]))
            }
        }
        for match in fwPattern.matches(in: content, range: range) {
            if let r = Range(match.range(at: 1), in: content) {
                frameworks.append(String(content[r]))
            }
        }

        return (libs, frameworks)
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
