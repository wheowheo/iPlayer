import AppKit
import CoreVideo
import QuartzCore
import SwiftUI

final class PlayerView: NSView {
    private let controller: PlayerController

    // 렌더링 레이어
    private let videoLayer = CALayer()

    // 컨트롤 바
    private let controlBar = NSView()
    private let rewindButton = NSButton()
    private let playButton = NSButton()
    private let forwardButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let seekBar = SeekBar()
    private let speedPopup = NSPopUpButton()
    private let volumeSlider = NSSlider()
    private let speedLabel = NSTextField(labelWithString: "1.0x")

    // 자막
    private let subtitleLabel = NSTextField(labelWithString: "")

    // 정보 오버레이
    private let infoOverlay = NSTextField(labelWithString: "")
    private let audioMeterView = AudioMeterView()
    private var showInfo = false
    private var showDebugger = false
    private var mediaInfo: PlayerController.MediaInfo?
    private var videoRotation: Double = 0

    // 컨트롤 숨기기 타이머
    private var hideTimer: Timer?
    private var controlsVisible = true

    // 창 드래그용
    private var isDraggingWindow = false
    private var windowDragStart: NSPoint = .zero

    // 드래그 앤 드롭
    private let supportedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    init(controller: PlayerController) {
        self.controller = controller
        super.init(frame: .zero)
        setupView()
        setupCallbacks()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    // 방향키가 시스템에 먹히지 않도록
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        switch event.keyCode {
        case 123, 124, 125, 126: // ← → ↓ ↑
            keyDown(with: event)
            return true
        case 48: // Tab
            keyDown(with: event)
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // 창이 활성화될 때마다 포커스 복구
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey),
            name: NSWindow.didBecomeKeyNotification, object: window
        )
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        window?.makeFirstResponder(self)
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)

        subtitleLabel.alignment = .center
        subtitleLabel.font = .systemFont(ofSize: 22, weight: .medium)
        subtitleLabel.textColor = .white
        subtitleLabel.backgroundColor = NSColor.black.withAlphaComponent(0.5)
        subtitleLabel.isBordered = false
        subtitleLabel.isEditable = false
        subtitleLabel.maximumNumberOfLines = 4
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.isHidden = true
        addSubview(subtitleLabel)

        infoOverlay.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        infoOverlay.textColor = .green
        infoOverlay.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        infoOverlay.isBordered = false
        infoOverlay.isEditable = false
        infoOverlay.maximumNumberOfLines = 20
        infoOverlay.isHidden = true
        addSubview(infoOverlay)

        audioMeterView.isHidden = true
        addSubview(audioMeterView)

        controlBar.wantsLayer = true
        controlBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        addSubview(controlBar)

        rewindButton.bezelStyle = .inline
        rewindButton.image = sfSymbol("gobackward.5", size: 14)
        rewindButton.imagePosition = .imageOnly
        rewindButton.contentTintColor = .white
        rewindButton.isBordered = false
        rewindButton.target = self
        rewindButton.action = #selector(rewindClicked)
        controlBar.addSubview(rewindButton)

        playButton.bezelStyle = .inline
        playButton.image = sfSymbol("play.fill", size: 16)
        playButton.imagePosition = .imageOnly
        playButton.contentTintColor = .white
        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(playButtonClicked)
        controlBar.addSubview(playButton)

        forwardButton.bezelStyle = .inline
        forwardButton.image = sfSymbol("goforward.5", size: 14)
        forwardButton.imagePosition = .imageOnly
        forwardButton.contentTintColor = .white
        forwardButton.isBordered = false
        forwardButton.target = self
        forwardButton.action = #selector(forwardClicked)
        controlBar.addSubview(forwardButton)

        seekBar.onSeek = { [weak self] fraction in
            guard let self = self else { return }
            let target = fraction * self.controller.duration
            self.controller.seek(to: target)
        }
        controlBar.addSubview(seekBar)

        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .white
        timeLabel.backgroundColor = .clear
        timeLabel.isBordered = false
        timeLabel.isEditable = false
        controlBar.addSubview(timeLabel)

        // 속도 선택 팝업
        speedPopup.pullsDown = false
        speedPopup.isBordered = false
        speedPopup.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        (speedPopup.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        for speed in ["0.25x", "0.5x", "0.75x", "1.0x", "1.25x", "1.5x", "2.0x", "3.0x", "4.0x"] {
            speedPopup.addItem(withTitle: speed)
        }
        speedPopup.selectItem(withTitle: "1.0x")
        speedPopup.target = self
        speedPopup.action = #selector(speedPopupChanged)
        controlBar.addSubview(speedPopup)

        volumeSlider.minValue = 0
        volumeSlider.maxValue = 2.0
        volumeSlider.doubleValue = 1.0
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        controlBar.addSubview(volumeSlider)

        speedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedLabel.textColor = .lightGray
        speedLabel.backgroundColor = .clear
        speedLabel.isBordered = false
        speedLabel.isEditable = false
        speedLabel.isHidden = true  // speedPopup으로 대체
        controlBar.addSubview(speedLabel)

        registerForDraggedTypes(supportedTypes)

        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    private func setupCallbacks() {
        controller.onFrameReady = { [weak self] frame in
            self?.displayFrame(frame)
        }

        controller.onTimeUpdate = { [weak self] current, total in
            guard let self = self else { return }
            if !self.seekBar.isSeeking {
                self.updateTimeDisplay(current: current, total: total)
            }
            if self.showInfo || self.showDebugger {
                self.updateInfoOverlay()
                self.updateAudioMeter()
            }
        }

        controller.onSubtitleUpdate = { [weak self] text in
            self?.updateSubtitle(text)
        }

        controller.onStateChange = { [weak self] state in
            self?.updatePlayButton(state: state)
        }

        let existingMediaInfo = controller.onMediaInfo
        controller.onMediaInfo = { [weak self] info in
            existingMediaInfo?(info)
            self?.mediaInfo = info
            self?.applyVideoRotation(info.rotation)
        }
    }

    private func applyVideoRotation(_ rotation: Double) {
        videoRotation = rotation
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if rotation == 0 {
            videoLayer.transform = CATransform3DIdentity
        } else {
            // CALayer는 y-up 좌표계: 양수 = 반시계 방향
            // rotation 값은 "이만큼 시계 방향으로 돌려야 정상"이므로 negate
            let radians = -rotation * .pi / 180.0
            videoLayer.transform = CATransform3DMakeRotation(CGFloat(radians), 0, 0, 1)
        }
        CATransaction.commit()
        needsLayout = true
    }

    override func layout() {
        super.layout()

        let bounds = self.bounds
        if videoRotation == 90 || videoRotation == 270 {
            let videoAspect = CGFloat(mediaInfo?.height ?? 9) / CGFloat(mediaInfo?.width ?? 16)
            let viewAspect = bounds.width / bounds.height
            var layerWidth: CGFloat
            var layerHeight: CGFloat
            if videoAspect > viewAspect {
                layerWidth = bounds.width
                layerHeight = bounds.width / videoAspect
            } else {
                layerHeight = bounds.height
                layerWidth = bounds.height * videoAspect
            }
            let layerFrame = NSRect(
                x: (bounds.width - layerWidth) / 2,
                y: (bounds.height - layerHeight) / 2,
                width: layerWidth,
                height: layerHeight
            )
            videoLayer.frame = layerFrame
            videoLayer.bounds = CGRect(x: 0, y: 0, width: layerHeight, height: layerWidth)
        } else {
            videoLayer.frame = bounds
            videoLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        }

        let barHeight: CGFloat = 50
        controlBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)

        let seekY: CGFloat = 30
        seekBar.frame = NSRect(x: 10, y: seekY, width: bounds.width - 20, height: 16)

        // 하단 버튼 행: [⏪] [▶] [⏩] | 시간 | ... | [속도] [볼륨]
        let btnW: CGFloat = 28
        let btnH: CGFloat = 24
        let btnY: CGFloat = 2
        var x: CGFloat = 8

        rewindButton.frame = NSRect(x: x, y: btnY, width: btnW, height: btnH)
        x += btnW
        playButton.frame = NSRect(x: x, y: btnY, width: btnW + 2, height: btnH)
        x += btnW + 2
        forwardButton.frame = NSRect(x: x, y: btnY, width: btnW, height: btnH)
        x += btnW + 6

        let timeLabelWidth: CGFloat = 130
        timeLabel.frame = NSRect(x: x, y: 4, width: timeLabelWidth, height: 20)

        let volWidth: CGFloat = 80
        let speedPopupWidth: CGFloat = 60
        speedPopup.frame = NSRect(x: bounds.width - volWidth - speedPopupWidth - 12, y: 2, width: speedPopupWidth, height: 22)
        volumeSlider.frame = NSRect(x: bounds.width - volWidth - 5, y: 4, width: volWidth, height: 20)
        speedLabel.frame = .zero

        let subHeight: CGFloat = 80
        subtitleLabel.frame = NSRect(x: 40, y: barHeight + 10, width: bounds.width - 80, height: subHeight)

        infoOverlay.frame = NSRect(x: 10, y: bounds.height - 180, width: 350, height: 170)

        let meterW: CGFloat = 300
        let meterH: CGFloat = 200
        audioMeterView.frame = NSRect(x: bounds.width - meterW - 10, y: bounds.height - meterH - 10,
                                      width: meterW, height: meterH)
    }

    // MARK: - 렌더링

    private func displayFrame(_ frame: VideoFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let pixelBuffer = frame.pixelBuffer {
            // CVPixelBuffer를 IOSurface로 직접 전달 (CIImage/NSImage 변환 제거)
            videoLayer.contents = pixelBuffer
        } else if let cgImage = frame.cgImage {
            videoLayer.contents = cgImage
        }
        CATransaction.commit()
    }

    private func updateTimeDisplay(current: Double, total: Double) {
        timeLabel.stringValue = "\(formatTime(current)) / \(formatTime(total))"
        if total > 0 {
            seekBar.progress = current / total
        }
    }

    private func updateSubtitle(_ text: String) {
        if text.isEmpty {
            subtitleLabel.isHidden = true
        } else {
            subtitleLabel.stringValue = text
            subtitleLabel.isHidden = false
        }
    }

    private func updatePlayButton(state: PlaybackState) {
        switch state {
        case .playing:
            playButton.image = sfSymbol("pause.fill", size: 16)
        case .paused, .stopped, .idle:
            playButton.image = sfSymbol("play.fill", size: 16)
        }
    }

    private func updateInfoOverlay() {
        guard showInfo || showDebugger else {
            infoOverlay.isHidden = true
            return
        }
        var text = ""

        if showInfo {
            let info = mediaInfo ?? PlayerController.MediaInfo()
            let rotStr = info.rotation != 0 ? " (rot: \(Int(info.rotation))°)" : ""
            text += """
            Time: \(formatTime(controller.currentTime)) / \(formatTime(controller.duration))
            FPS: \(String(format: "%.1f", controller.currentFPS))
            Video: \(info.videoCodec) \(info.width)x\(info.height)\(rotStr)
            Display: \(info.displayWidth)x\(info.displayHeight)
            Video Bitrate: \(info.videoBitRate / 1000) kbps
            Audio: \(info.audioCodec) \(info.audioSampleRate)Hz \(info.audioChannels)ch
            Audio Bitrate: \(info.audioBitRate / 1000) kbps
            Decode: \(info.hwAccelerated ? "Hardware (VideoToolbox)" : "Software")
            Render: \(controller.renderMode.rawValue)
            Speed: \(String(format: "%.2fx", controller.playbackSpeed))
            Dropped: \(controller.droppedFrames) frames
            A/V Drift: \(String(format: "%+.1f", controller.avSyncDrift * 1000))ms
            """
        }

        if showDebugger {
            if showInfo { text += "\n" }
            text += controller.dropDebugger.summary
        }

        infoOverlay.stringValue = text
        infoOverlay.isHidden = false

        // 디버거 켜지면 오버레이 크기 확장
        let height: CGFloat = showDebugger ? 340 : 170
        infoOverlay.frame = NSRect(x: 10, y: bounds.height - height - 10, width: 400, height: height)
    }

    private func updateAudioMeter() {
        guard showInfo else {
            audioMeterView.isHidden = true
            return
        }
        let data = controller.audioOutput.getDisplayData()
        audioMeterView.update(levelL: data.levelL, levelR: data.levelR,
                              peakL: data.peakL, peakR: data.peakR, pcm: data.pcm)
        audioMeterView.isHidden = false
    }

    // MARK: - 키보드 입력

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // Space
            playOrResume()
        case 3: // F
            if event.modifierFlags.contains(.command) {
                window?.toggleFullScreen(nil)
            } else {
                controller.stepFrame()
            }
        case 123: // ←
            controller.seekRelative(seconds: -5)
        case 124: // →
            controller.seekRelative(seconds: 5)
        case 126: // ↑
            adjustVolume(delta: 0.05)
        case 125: // ↓
            adjustVolume(delta: -0.05)
        case 33: // [
            adjustSpeed(delta: -0.25)
        case 30: // ]
            adjustSpeed(delta: 0.25)
        case 48: // Tab
            showInfo.toggle()
            updateInfoOverlay()
            updateAudioMeter()
        case 46: // M
            controller.isMuted.toggle()
        case 31: // O
            NSApp.sendAction(#selector(AppDelegate.openFileAction(_:)), to: nil, from: self)
        case 53: // Esc
            if let window = self.window, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                controller.stop()
            }
        case 27: // -
            controller.subtitleOffset -= 0.5
            log("자막 오프셋: \(controller.subtitleOffset)초")
        case 24: // =
            controller.subtitleOffset += 0.5
            log("자막 오프셋: \(controller.subtitleOffset)초")
        case 15: // R
            controller.toggleRenderMode()
        case 2: // D
            showDebugger.toggle()
            controller.dropDebugger.isEnabled = showDebugger
            updateInfoOverlay()
        case 18: // 1
            resizeWindow(scale: 0.5)
        case 19: // 2
            resizeWindow(scale: 1.0)
        case 20: // 3
            resizeWindow(scale: 2.0)
        default:
            super.keyDown(with: event)
        }
    }

    private func resizeWindow(scale: CGFloat) {
        guard let info = mediaInfo, info.displayWidth > 0, info.displayHeight > 0,
              let win = window else { return }
        let screen = win.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)

        var w = CGFloat(info.displayWidth) * scale
        var h = CGFloat(info.displayHeight) * scale

        // 화면 크기 초과 시 맞춤
        if w > screen.width || h > screen.height {
            let ratio = CGFloat(info.displayWidth) / CGFloat(info.displayHeight)
            if w / screen.width > h / screen.height {
                w = screen.width
                h = w / ratio
            } else {
                h = screen.height
                w = h * ratio
            }
        }

        win.setContentSize(NSSize(width: w, height: h))
        win.center()
    }

    private func adjustVolume(delta: Float) {
        controller.volume = max(0, min(2.0, controller.volume + delta))
        volumeSlider.doubleValue = Double(controller.volume)
    }

    private func adjustSpeed(delta: Float) {
        controller.playbackSpeed = max(0.25, min(4.0, controller.playbackSpeed + delta))
        speedLabel.stringValue = String(format: "%.2fx", controller.playbackSpeed)
        syncSpeedPopup()
    }

    private func syncSpeedPopup() {
        let title = String(format: "%.2gx", controller.playbackSpeed)
        let idx = speedPopup.indexOfItem(withTitle: title)
        if idx >= 0 {
            speedPopup.selectItem(at: idx)
        } else {
            // 정확한 프리셋이 없으면 가장 가까운 것 선택
            let speeds: [Float] = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]
            let closest = speeds.enumerated().min(by: { abs($0.element - controller.playbackSpeed) < abs($1.element - controller.playbackSpeed) })
            if let idx = closest?.offset { speedPopup.selectItem(at: idx) }
        }
    }

    // MARK: - 마우스: 창 드래그 이동

    override func mouseDown(with event: NSEvent) {
        // 클릭할 때마다 포커스를 PlayerView로 복귀
        window?.makeFirstResponder(self)

        let locationInView = convert(event.locationInWindow, from: nil)

        // 컨트롤 바 영역이면 창 드래그 안 함
        if controlBar.frame.contains(locationInView) {
            super.mouseDown(with: event)
            return
        }

        // 비디오 영역 클릭 → 창 드래그 시작
        isDraggingWindow = true
        windowDragStart = event.locationInWindow
        showControls()
    }

    override func mouseDragged(with event: NSEvent) {
        if isDraggingWindow, let win = window {
            let current = event.locationInWindow
            let dx = current.x - windowDragStart.x
            let dy = current.y - windowDragStart.y
            var origin = win.frame.origin
            origin.x += dx
            origin.y += dy
            win.setFrameOrigin(origin)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingWindow = false
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        adjustVolume(delta: Float(event.deltaY) * 0.02)
    }

    override func mouseMoved(with event: NSEvent) {
        showControls()
    }

    private func showControls() {
        controlBar.isHidden = false
        controlsVisible = true
        NSCursor.unhide()
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, self.controller.state == .playing else { return }
                self.controlBar.isHidden = true
                self.controlsVisible = false
                NSCursor.hide()
            }
        }
    }

    // MARK: - 액션

    @objc private func playButtonClicked() {
        playOrResume()
        window?.makeFirstResponder(self)
    }

    @objc private func rewindClicked() {
        controller.seekRelative(seconds: -5)
        window?.makeFirstResponder(self)
    }

    @objc private func forwardClicked() {
        controller.seekRelative(seconds: 5)
        window?.makeFirstResponder(self)
    }

    @objc private func speedPopupChanged() {
        guard let title = speedPopup.selectedItem?.title else { return }
        let value = title.replacingOccurrences(of: "x", with: "")
        if let speed = Float(value) {
            controller.playbackSpeed = speed
            speedLabel.stringValue = String(format: "%.2fx", speed)
        }
        window?.makeFirstResponder(self)
    }

    private func playOrResume() {
        // 파일이 로드되어 있으면 그냥 토글
        if controller.demuxer.formatCtx != nil {
            controller.togglePlayPause()
            return
        }

        // 파일이 없으면 최근 파일 목록에서 첫 번째 파일 재생 시도
        let recent = UserDefaults.standard.stringArray(forKey: "iPlayer.recentFiles") ?? []
        guard let lastPath = recent.first else {
            // 최근 파일도 없음
            controller.togglePlayPause()
            return
        }

        if FileManager.default.fileExists(atPath: lastPath) {
            controller.openFile(path: lastPath)
        } else {
            // 파일이 삭제됨
            let alert = NSAlert()
            alert.messageText = "파일을 찾을 수 없음"
            alert.informativeText = "'\(URL(fileURLWithPath: lastPath).lastPathComponent)' 파일이 해당 위치에 존재하지 않습니다."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "확인")
            alert.runModal()
        }
    }

    @objc private func volumeChanged() {
        controller.volume = Float(volumeSlider.doubleValue)
        window?.makeFirstResponder(self)
    }

    @objc private func doubleClicked(_ gesture: NSClickGestureRecognizer) {
        window?.zoom(nil)
    }

    // MARK: - 드래그 앤 드롭 (파일)

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let canRead = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
        return canRead ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let url = urls.first {
            openDroppedURL(url)
            return true
        }
        if let files = pb.propertyList(forType: .fileURL) as? String, let url = URL(string: files) {
            openDroppedURL(url)
            return true
        }
        if let path = pb.string(forType: .string), FileManager.default.fileExists(atPath: path) {
            openDroppedURL(URL(fileURLWithPath: path))
            return true
        }
        return false
    }

    private func openDroppedURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if ext == "srt" || ext == "smi" || ext == "smil" {
            controller.loadSubtitle(path: url.path)
        } else {
            controller.openFile(path: url.path)
        }
    }

    // MARK: - 우클릭 컨텍스트 메뉴

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()

        // 재생/일시정지
        let playTitle = controller.state == .playing ? "일시정지" : "재생"
        let playItem = NSMenuItem(title: playTitle, action: #selector(contextPlayPause), keyEquivalent: "")
        playItem.target = self
        menu.addItem(playItem)

        // 정지
        let stopItem = NSMenuItem(title: "정지", action: #selector(contextStop), keyEquivalent: "")
        stopItem.target = self
        menu.addItem(stopItem)

        menu.addItem(NSMenuItem.separator())

        // 파일 열기
        let openItem = NSMenuItem(title: "파일 열기...", action: #selector(AppDelegate.openFileAction(_:)), keyEquivalent: "")
        menu.addItem(openItem)

        // 자막 열기
        let subItem = NSMenuItem(title: "자막 열기...", action: #selector(AppDelegate.openSubtitleAction(_:)), keyEquivalent: "")
        menu.addItem(subItem)

        menu.addItem(NSMenuItem.separator())

        // 배속
        let speedMenu = NSMenu()
        for speed: Float in [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0] {
            let item = NSMenuItem(title: String(format: "%.2fx", speed), action: #selector(contextSetSpeed(_:)), keyEquivalent: "")
            item.tag = Int(speed * 100)
            item.target = self
            if abs(controller.playbackSpeed - speed) < 0.01 {
                item.state = .on
            }
            speedMenu.addItem(item)
        }
        let speedMenuItem = NSMenuItem(title: "재생 속도", action: nil, keyEquivalent: "")
        speedMenuItem.submenu = speedMenu
        menu.addItem(speedMenuItem)

        // 볼륨
        let volMenu = NSMenu()
        for vol in [0, 25, 50, 75, 100, 125, 150, 200] {
            let title = vol == 0 ? "음소거" : "\(vol)%"
            let item = NSMenuItem(title: title, action: #selector(contextSetVolume(_:)), keyEquivalent: "")
            item.tag = vol
            item.target = self
            let currentVol = controller.isMuted ? 0 : Int(controller.volume * 100)
            if vol == currentVol {
                item.state = .on
            }
            volMenu.addItem(item)
        }
        let volMenuItem = NSMenuItem(title: "볼륨", action: nil, keyEquivalent: "")
        volMenuItem.submenu = volMenu
        menu.addItem(volMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 오디오 트랙
        if !controller.demuxer.audioStreams.isEmpty {
            let audioMenu = NSMenu()
            for (i, audio) in controller.demuxer.audioStreams.enumerated() {
                let title = "\(i + 1). \(audio.stream.codecName) \(audio.sampleRate)Hz \(audio.channels)ch"
                let item = NSMenuItem(title: title, action: #selector(contextSelectAudioTrack(_:)), keyEquivalent: "")
                item.tag = Int(audio.stream.index)
                item.target = self
                if audio.stream.index == controller.demuxer.selectedAudioIndex {
                    item.state = .on
                }
                audioMenu.addItem(item)
            }
            let audioMenuItem = NSMenuItem(title: "오디오 트랙", action: nil, keyEquivalent: "")
            audioMenuItem.submenu = audioMenu
            menu.addItem(audioMenuItem)
        }

        // 자막 트랙
        if !controller.demuxer.subtitleStreams.isEmpty {
            let subTrackMenu = NSMenu()
            for (i, sub) in controller.demuxer.subtitleStreams.enumerated() {
                let title = "\(i + 1). \(sub.codecName)"
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if sub.index == controller.demuxer.selectedSubtitleIndex {
                    item.state = .on
                }
                subTrackMenu.addItem(item)
            }
            let subTrackMenuItem = NSMenuItem(title: "자막 트랙", action: nil, keyEquivalent: "")
            subTrackMenuItem.submenu = subTrackMenu
            menu.addItem(subTrackMenuItem)
        }

        menu.addItem(NSMenuItem.separator())

        // 전체화면
        let fullscreenTitle = window?.styleMask.contains(.fullScreen) == true ? "전체화면 해제" : "전체화면"
        let fsItem = NSMenuItem(title: fullscreenTitle, action: #selector(contextToggleFullscreen), keyEquivalent: "")
        fsItem.target = self
        menu.addItem(fsItem)

        // 정보 오버레이
        let infoTitle = showInfo ? "정보 숨기기" : "정보 표시"
        let infoItem = NSMenuItem(title: infoTitle, action: #selector(contextToggleInfo), keyEquivalent: "")
        infoItem.target = self
        menu.addItem(infoItem)

        // 드롭 디버거
        let debugTitle = showDebugger ? "드롭 디버거 끄기" : "드롭 디버거 켜기"
        let debugItem = NSMenuItem(title: debugTitle, action: #selector(contextToggleDebugger), keyEquivalent: "")
        debugItem.target = self
        menu.addItem(debugItem)

        // 렌더 모드
        let renderMenu = NSMenu()
        for mode: RenderMode in [.displayLink, .thread] {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(contextSetRenderMode(_:)), keyEquivalent: "")
            item.tag = mode == .displayLink ? 0 : 1
            item.target = self
            if controller.renderMode == mode { item.state = .on }
            renderMenu.addItem(item)
        }
        let renderMenuItem = NSMenuItem(title: "렌더 모드", action: nil, keyEquivalent: "")
        renderMenuItem.submenu = renderMenu
        menu.addItem(renderMenuItem)

        menu.addItem(NSMenuItem.separator())

        // 라이브러리 정보
        let libItem = NSMenuItem(title: "라이브러리 정보", action: #selector(AppDelegate.showLibraryInfo(_:)), keyEquivalent: "")
        menu.addItem(libItem)

        return menu
    }

    @objc private func contextPlayPause() { playOrResume() }
    @objc private func contextStop() { controller.stop() }

    @objc private func contextSetSpeed(_ sender: NSMenuItem) {
        let speed = Float(sender.tag) / 100.0
        controller.playbackSpeed = speed
        speedLabel.stringValue = String(format: "%.2fx", speed)
        syncSpeedPopup()
    }

    @objc private func contextSetVolume(_ sender: NSMenuItem) {
        let vol = Float(sender.tag) / 100.0
        if sender.tag == 0 {
            controller.isMuted = true
        } else {
            controller.isMuted = false
            controller.volume = vol
            volumeSlider.doubleValue = Double(vol)
        }
    }

    @objc private func contextSelectAudioTrack(_ sender: NSMenuItem) {
        controller.selectAudioTrack(index: Int32(sender.tag))
    }

    @objc private func contextToggleFullscreen() {
        window?.toggleFullScreen(nil)
    }

    @objc private func contextToggleInfo() {
        showInfo.toggle()
        updateInfoOverlay()
        updateAudioMeter()
    }

    @objc private func contextSetRenderMode(_ sender: NSMenuItem) {
        controller.renderMode = sender.tag == 0 ? .displayLink : .thread
    }

    @objc private func contextToggleDebugger() {
        showDebugger.toggle()
        controller.dropDebugger.isEnabled = showDebugger
        updateInfoOverlay()
    }

    // MARK: - 유틸

    private func sfSymbol(_ name: String, size: CGFloat) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "00:00" }
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

// MARK: - 시크바

final class SeekBar: NSView {
    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }
    var onSeek: ((Double) -> Void)?
    private(set) var isSeeking = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let trackHeight: CGFloat = 4
        let trackY = (bounds.height - trackHeight) / 2

        NSColor.darkGray.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: trackY, width: bounds.width, height: trackHeight),
                     xRadius: 2, yRadius: 2).fill()

        let progressWidth = bounds.width * CGFloat(progress)
        NSColor.systemBlue.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: trackY, width: progressWidth, height: trackHeight),
                     xRadius: 2, yRadius: 2).fill()

        let handleSize: CGFloat = 12
        let handleX = progressWidth - handleSize / 2
        let handleY = (bounds.height - handleSize) / 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: handleX, y: handleY, width: handleSize, height: handleSize)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        isSeeking = true
        handleSeek(event, commit: true)
    }

    override func mouseDragged(with event: NSEvent) {
        handleSeek(event, commit: false)
    }

    override func mouseUp(with event: NSEvent) {
        handleSeek(event, commit: true)
        isSeeking = false
    }

    private func handleSeek(_ event: NSEvent, commit: Bool) {
        let location = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, Double(location.x / bounds.width)))
        // seekbar를 즉시 업데이트
        progress = fraction
        needsDisplay = true
        // 실제 seek 수행 (드래그 중에도 수행하여 화면도 같이 전환)
        onSeek?(fraction)
    }
}

// MARK: - SwiftUI Preview

struct PlayerViewRepresentable: NSViewRepresentable {
    let controller: PlayerController

    func makeNSView(context: Context) -> PlayerView {
        PlayerView(controller: controller)
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {}
}

#Preview("iPlayer") {
    PlayerViewRepresentable(controller: PlayerController())
        .frame(width: 960, height: 540)
}
