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

    // 컨트롤 숨기기 타이머
    private var hideTimer: Timer?
    private var controlsVisible = true

    // 드래그 앤 드롭
    private let supportedTypes: [NSPasteboard.PasteboardType] = [.fileURL]

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    private func setupView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        // 비디오 레이어
        videoLayer.contentsGravity = .resizeAspect
        videoLayer.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(videoLayer)

        // 자막
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

        // 정보 오버레이
        infoOverlay.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        infoOverlay.textColor = .green
        infoOverlay.backgroundColor = NSColor.black.withAlphaComponent(0.7)
        infoOverlay.isBordered = false
        infoOverlay.isEditable = false
        infoOverlay.maximumNumberOfLines = 20
        infoOverlay.isHidden = true
        addSubview(infoOverlay)

        // 컨트롤 바
        controlBar.wantsLayer = true
        controlBar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        addSubview(controlBar)

        // 재생 버튼
        playButton.bezelStyle = .inline
        playButton.title = "▶"
        playButton.font = .systemFont(ofSize: 16)
        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(playButtonClicked)
        controlBar.addSubview(playButton)

        // 시크바
        seekBar.onSeek = { [weak self] fraction in
            guard let self = self else { return }
            let target = fraction * self.controller.duration
            self.controller.seek(to: target)
        }
        controlBar.addSubview(seekBar)

        // 시간 라벨
        timeLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .white
        timeLabel.backgroundColor = .clear
        timeLabel.isBordered = false
        timeLabel.isEditable = false
        controlBar.addSubview(timeLabel)

        // 볼륨
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 2.0
        volumeSlider.doubleValue = 1.0
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        controlBar.addSubview(volumeSlider)

        // 속도 라벨
        speedLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        speedLabel.textColor = .lightGray
        speedLabel.backgroundColor = .clear
        speedLabel.isBordered = false
        speedLabel.isEditable = false
        controlBar.addSubview(speedLabel)

        // 드래그 앤 드롭
        registerForDraggedTypes(supportedTypes)

        // 더블클릭 -> 전체화면
        let doubleClick = NSClickGestureRecognizer(target: self, action: #selector(doubleClicked))
        doubleClick.numberOfClicksRequired = 2
        addGestureRecognizer(doubleClick)
    }

    private func setupCallbacks() {
        controller.onFrameReady = { [weak self] frame in
            self?.displayFrame(frame)
        }

        controller.onTimeUpdate = { [weak self] current, total in
            self?.updateTimeDisplay(current: current, total: total)
        }

        controller.onSubtitleUpdate = { [weak self] text in
            self?.updateSubtitle(text)
        }

        controller.onStateChange = { [weak self] state in
            self?.updatePlayButton(state: state)
        }

        controller.onMediaInfo = { [weak self] info in
            self?.mediaInfo = info
        }
    }

    override func layout() {
        super.layout()

        let bounds = self.bounds
        videoLayer.frame = bounds

        // 컨트롤 바
        let barHeight: CGFloat = 50
        controlBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)

        // 시크바
        let seekY: CGFloat = 30
        seekBar.frame = NSRect(x: 10, y: seekY, width: bounds.width - 20, height: 16)

        // 하단 컨트롤
        let btnSize: CGFloat = 30
        playButton.frame = NSRect(x: 10, y: 2, width: btnSize, height: 24)

        let timeLabelWidth: CGFloat = 130
        timeLabel.frame = NSRect(x: btnSize + 15, y: 4, width: timeLabelWidth, height: 20)

        let volWidth: CGFloat = 80
        speedLabel.frame = NSRect(x: bounds.width - volWidth - 50, y: 4, width: 40, height: 20)
        volumeSlider.frame = NSRect(x: bounds.width - volWidth - 5, y: 4, width: volWidth, height: 20)

        // 자막
        let subHeight: CGFloat = 80
        subtitleLabel.frame = NSRect(x: 40, y: barHeight + 10, width: bounds.width - 80, height: subHeight)

        // 정보 오버레이
        infoOverlay.frame = NSRect(x: 10, y: bounds.height - 180, width: 350, height: 170)
    }

    // MARK: - 렌더링

    private func displayFrame(_ frame: VideoFrame) {
        if let pixelBuffer = frame.pixelBuffer {
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            let rep = NSCIImageRep(ciImage: ciImage)
            let nsImage = NSImage(size: rep.size)
            nsImage.addRepresentation(rep)
            videoLayer.contents = nsImage
        } else if let cgImage = frame.cgImage {
            videoLayer.contents = cgImage
        }
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
        let text = """
        FPS: \(String(format: "%.1f", controller.currentFPS))
        Video: \(info.videoCodec) \(info.width)x\(info.height)
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
            controller.stepFrame()
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
        case 53: // Esc
            if let window = self.window, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                controller.stop()
            }
        case 27: // - (자막 싱크 뒤로)
            controller.subtitleOffset -= 0.5
            log("자막 오프셋: \(controller.subtitleOffset)초")
        case 24: // = (자막 싱크 앞으로)
            controller.subtitleOffset += 0.5
            log("자막 오프셋: \(controller.subtitleOffset)초")
        default:
            super.keyDown(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Cmd+F 전체화면
        if event.modifierFlags.contains(.command) {
            // Cmd 키 감지 (F는 keyDown에서 처리)
        }
        super.flagsChanged(with: event)
    }

    private func adjustVolume(delta: Float) {
        controller.volume = max(0, min(2.0, controller.volume + delta))
        volumeSlider.doubleValue = Double(controller.volume)
    }

    private func adjustSpeed(delta: Float) {
        controller.playbackSpeed = max(0.25, min(4.0, controller.playbackSpeed + delta))
        speedLabel.stringValue = String(format: "%.2fx", controller.playbackSpeed)
    }

    // MARK: - 마우스

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
    }

    @objc private func volumeChanged() {
        controller.volume = Float(volumeSlider.doubleValue)
    }

    @objc private func doubleClicked(_ gesture: NSClickGestureRecognizer) {
        window?.toggleFullScreen(nil)
    }

    // MARK: - 드래그 앤 드롭

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let items = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL],
              let url = items.first else {
            return false
        }

        let ext = url.pathExtension.lowercased()
        if ext == "srt" || ext == "smi" || ext == "smil" {
            controller.loadSubtitle(path: url.path)
        } else {
            controller.openFile(path: url.path)
        }
        return true
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

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let trackHeight: CGFloat = 4
        let trackY = (bounds.height - trackHeight) / 2

        // 트랙 배경
        NSColor.darkGray.setFill()
        let trackRect = NSRect(x: 0, y: trackY, width: bounds.width, height: trackHeight)
        NSBezierPath(roundedRect: trackRect, xRadius: 2, yRadius: 2).fill()

        // 진행 바
        let progressWidth = bounds.width * CGFloat(progress)
        NSColor.systemBlue.setFill()
        let progressRect = NSRect(x: 0, y: trackY, width: progressWidth, height: trackHeight)
        NSBezierPath(roundedRect: progressRect, xRadius: 2, yRadius: 2).fill()

        // 핸들
        let handleSize: CGFloat = 12
        let handleX = progressWidth - handleSize / 2
        let handleY = (bounds.height - handleSize) / 2
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: handleX, y: handleY, width: handleSize, height: handleSize)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        handleSeek(event)
    }

    override func mouseDragged(with event: NSEvent) {
        handleSeek(event)
    }

    private func handleSeek(_ event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let fraction = max(0, min(1, Double(location.x / bounds.width)))
        progress = fraction
        onSeek?(fraction)
    }
}
