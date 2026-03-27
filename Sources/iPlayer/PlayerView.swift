import AppKit
import CoreVideo
import QuartzCore

final class PlayerView: NSView {
    private let controller: PlayerController

    // 렌더링 레이어
    private let videoLayer = CALayer()

    // 컨트롤 바
    private let controlBar = NSView()
    private let playButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "00:00 / 00:00")
    private let seekBar = SeekBar()
    private let volumeSlider = NSSlider()
    private let speedLabel = NSTextField(labelWithString: "1.0x")

    // 자막
    private let subtitleLabel = NSTextField(labelWithString: "")

    // 정보 오버레이
    private let infoOverlay = NSTextField(labelWithString: "")
    private var showInfo = false
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

        controlBar.wantsLayer = true
        controlBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        addSubview(controlBar)

        playButton.bezelStyle = .inline
        playButton.title = "▶"
        playButton.font = .systemFont(ofSize: 16)
        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(playButtonClicked)
        controlBar.addSubview(playButton)

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
            if self.showInfo {
                self.updateInfoOverlay()
            }
        }

        controller.onSubtitleUpdate = { [weak self] text in
            self?.updateSubtitle(text)
        }

        controller.onStateChange = { [weak self] state in
            self?.updatePlayButton(state: state)
        }

        controller.onMediaInfo = { [weak self] info in
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
            let radians = rotation * .pi / 180.0
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

        let btnSize: CGFloat = 30
        playButton.frame = NSRect(x: 10, y: 2, width: btnSize, height: 24)

        let timeLabelWidth: CGFloat = 130
        timeLabel.frame = NSRect(x: btnSize + 15, y: 4, width: timeLabelWidth, height: 20)

        let volWidth: CGFloat = 80
        speedLabel.frame = NSRect(x: bounds.width - volWidth - 50, y: 4, width: 40, height: 20)
        volumeSlider.frame = NSRect(x: bounds.width - volWidth - 5, y: 4, width: volWidth, height: 20)

        let subHeight: CGFloat = 80
        subtitleLabel.frame = NSRect(x: 40, y: barHeight + 10, width: bounds.width - 80, height: subHeight)

        infoOverlay.frame = NSRect(x: 10, y: bounds.height - 180, width: 350, height: 170)
    }

    // MARK: - 렌더링

    private func displayFrame(_ frame: VideoFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let pixelBuffer = frame.pixelBuffer {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rep = NSCIImageRep(ciImage: ciImage)
            let nsImage = NSImage(size: rep.size)
            nsImage.addRepresentation(rep)
            videoLayer.contents = nsImage
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
        case .playing: playButton.title = "⏸"
        case .paused: playButton.title = "▶"
        case .stopped, .idle: playButton.title = "▶"
        }
    }

    private func updateInfoOverlay() {
        guard showInfo else {
            infoOverlay.isHidden = true
            return
        }
        let info = mediaInfo ?? PlayerController.MediaInfo()
        let rotStr = info.rotation != 0 ? " (rot: \(Int(info.rotation))°)" : ""
        let text = """
        Time: \(formatTime(controller.currentTime)) / \(formatTime(controller.duration))
        FPS: \(String(format: "%.1f", controller.currentFPS))
        Video: \(info.videoCodec) \(info.width)x\(info.height)\(rotStr)
        Display: \(info.displayWidth)x\(info.displayHeight)
        Video Bitrate: \(info.videoBitRate / 1000) kbps
        Audio: \(info.audioCodec) \(info.audioSampleRate)Hz \(info.audioChannels)ch
        Audio Bitrate: \(info.audioBitRate / 1000) kbps
        Decode: \(info.hwAccelerated ? "Hardware (VideoToolbox)" : "Software")
        Speed: \(String(format: "%.2fx", controller.playbackSpeed))
        Dropped: \(controller.droppedFrames) frames
        """
        infoOverlay.stringValue = text
        infoOverlay.isHidden = false
    }

    // MARK: - 키보드 입력

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 49: // Space
            controller.togglePlayPause()
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
        default:
            super.keyDown(with: event)
        }
    }

    private func adjustVolume(delta: Float) {
        controller.volume = max(0, min(2.0, controller.volume + delta))
        volumeSlider.doubleValue = Double(controller.volume)
    }

    private func adjustSpeed(delta: Float) {
        controller.playbackSpeed = max(0.25, min(4.0, controller.playbackSpeed + delta))
        speedLabel.stringValue = String(format: "%.2fx", controller.playbackSpeed)
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
        controller.togglePlayPause()
        window?.makeFirstResponder(self)
    }

    @objc private func volumeChanged() {
        controller.volume = Float(volumeSlider.doubleValue)
        window?.makeFirstResponder(self)
    }

    @objc private func doubleClicked(_ gesture: NSClickGestureRecognizer) {
        window?.toggleFullScreen(nil)
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

    // MARK: - 유틸

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
