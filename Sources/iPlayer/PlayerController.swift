import Foundation
import CFFmpeg
import AppKit
import CoreVideo
import QuartzCore

enum PlaybackState {
    case idle
    case playing
    case paused
    case stopped
}

enum RenderMode: String {
    case displayLink = "CVDisplayLink"
    case thread = "Thread"
}

final class PlayerController: @unchecked Sendable {
    let demuxer = Demuxer()
    let videoDecoder = VideoDecoder()
    let audioDecoder = AudioDecoder()
    let audioOutput = AudioOutput()

    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var filePath: String = ""

    var playbackSpeed: Float = 1.0 {
        didSet { audioOutput.playbackRate = playbackSpeed }
    }
    var volume: Float = 1.0 {
        didSet { audioOutput.volume = volume }
    }
    var isMuted: Bool = false {
        didSet { audioOutput.isMuted = isMuted }
    }

    private(set) var subtitles: [SubtitleEntry] = []
    var subtitleOffset: Double = 0
    private(set) var currentSubtitle: String = ""

    var onFrameReady: ((VideoFrame) -> Void)?
    var onTimeUpdate: ((Double, Double) -> Void)?
    var onSubtitleUpdate: ((String) -> Void)?
    var onStateChange: ((PlaybackState) -> Void)?
    var onMediaInfo: ((MediaInfo) -> Void)?
    var onRenderModeChange: ((RenderMode) -> Void)?

    // 렌더 모드
    var renderMode: RenderMode = .displayLink {
        didSet {
            guard renderMode != oldValue else { return }
            if state == .playing {
                stopRenderer()
                startRenderer()
            }
            onRenderModeChange?(renderMode)
        }
    }

    // 스레드
    private var readThread: Thread?
    private var renderThread: Thread?
    private var isReading = false
    private var isRendering = false
    private let readThreadDone = DispatchSemaphore(value: 0)
    private let renderThreadDone = DispatchSemaphore(value: 0)

    // CVDisplayLink
    private var displayLink: CVDisplayLink?
    private var displayLinkRunning = false
    private var displayLinkSelfPtr: UnsafeMutableRawPointer?

    // 프레임 큐 (원형 버퍼 - removeFirst O(1))
    private var frameRing = FrameRingBuffer(capacity: 256)
    private let queueLock = NSLock()

    // seek 제어: read thread가 직접 수행
    private var seekRequest: Double? = nil
    private let seekLock = NSLock()

    // 통계
    private(set) var droppedFrames: Int = 0
    private(set) var renderedFrames: Int = 0
    private var fpsCounter = 0
    private var fpsTimerStart: Double = 0
    private(set) var currentFPS: Double = 0

    // 재생 클럭
    private var playbackStartWall: Double = 0
    private var playbackStartPTS: Double = 0
    private var hasAudio: Bool = false

    // 프레임 간격 (fps 기반)
    private var frameDuration: Double = 1.0 / 30.0
    private var dropThreshold: Double = -3.0 / 30.0
    private var showThreshold: Double = 0.5 / 30.0

    // 싱크 통계
    private(set) var avSyncDrift: Double = 0

    // UI 업데이트 카운터
    private var uiUpdateCounter = 0

    struct MediaInfo {
        var videoCodec: String = ""
        var audioCodec: String = ""
        var width: Int32 = 0
        var height: Int32 = 0
        var displayWidth: Int32 = 0
        var displayHeight: Int32 = 0
        var rotation: Double = 0
        var videoBitRate: Int64 = 0
        var audioBitRate: Int64 = 0
        var audioSampleRate: Int32 = 0
        var audioChannels: Int32 = 0
        var fps: Double = 0
        var hwAccelerated: Bool = false
        var duration: Double = 0
    }

    // MARK: - 공개 API

    func openFile(path: String) {
        stop()

        guard demuxer.open(path: path) else {
            log("[Player] 파일 열기 실패")
            return
        }
        filePath = path
        duration = demuxer.duration

        if demuxer.selectedVideoIndex >= 0, let fmtCtx = demuxer.formatCtx {
            guard videoDecoder.open(formatCtx: fmtCtx, streamIndex: demuxer.selectedVideoIndex) else {
                log("[Player] 비디오 디코더 열기 실패")
                return
            }
        }

        hasAudio = false
        if demuxer.selectedAudioIndex >= 0, let fmtCtx = demuxer.formatCtx {
            if audioDecoder.open(formatCtx: fmtCtx, streamIndex: demuxer.selectedAudioIndex) {
                hasAudio = true
            }
        }

        // 프레임 타이밍 계산
        updateFrameTiming()

        loadSubtitleAutomatic(videoPath: path)

        let info = buildMediaInfo()
        DispatchQueue.main.async { [weak self] in
            self?.onMediaInfo?(info)
        }

        play()
    }

    func play() {
        guard state != .playing else { return }
        guard demuxer.formatCtx != nil else { return }

        if state == .idle || state == .stopped {
            if hasAudio { _ = audioOutput.start() }
            startReadThread()
            Thread.sleep(forTimeInterval: 0.15)
            startRenderer()
        } else if state == .paused {
            if hasAudio { audioOutput.resume() }
            resetClock(fromPTS: currentTime)
            startRenderer()
        }

        state = .playing
        onStateChange?(state)
    }

    func pause() {
        guard state == .playing else { return }
        if hasAudio { audioOutput.pause() }
        stopRenderer()
        state = .paused
        onStateChange?(state)
    }

    func togglePlayPause() {
        if state == .playing { pause() }
        else { play() }
    }

    func stop() {
        stopRenderer()
        stopReadThread()

        audioOutput.stop()
        videoDecoder.close()
        audioDecoder.close()
        demuxer.close()

        queueLock.lock()
        frameRing.removeAll()
        queueLock.unlock()

        seekLock.lock()
        seekRequest = nil
        seekLock.unlock()

        currentTime = 0
        droppedFrames = 0
        renderedFrames = 0
        subtitles.removeAll()
        currentSubtitle = ""
        hasAudio = false
        state = .stopped
        onStateChange?(state)
    }

    func seek(to seconds: Double) {
        guard demuxer.formatCtx != nil else { return }
        let target = max(0, min(seconds, duration))
        seekLock.lock()
        seekRequest = target
        seekLock.unlock()
    }

    func seekRelative(seconds: Double) {
        seek(to: currentTime + seconds)
    }

    func stepFrame() {
        guard demuxer.formatCtx != nil else { return }
        if state == .playing { pause() }

        queueLock.lock()
        if let frame = frameRing.first {
            frameRing.removeFirst()
            queueLock.unlock()
            currentTime = min(frame.pts, duration)
            DispatchQueue.main.async { [weak self] in
                self?.onFrameReady?(frame)
                guard let self = self else { return }
                self.onTimeUpdate?(self.currentTime, self.duration)
                self.updateSubtitle()
            }
        } else {
            queueLock.unlock()
        }
    }

    func selectAudioTrack(index: Int32) {
        guard let fmtCtx = demuxer.formatCtx else { return }
        let wasPlaying = state == .playing
        if wasPlaying { pause() }

        let savedTime = currentTime
        audioDecoder.close()
        demuxer.selectedAudioIndex = index

        if audioDecoder.open(formatCtx: fmtCtx, streamIndex: index) {
            hasAudio = true
            log("[Player] 오디오 트랙 변경: \(index)")
        }

        if wasPlaying {
            seek(to: savedTime)
            play()
        }
    }

    func loadSubtitle(path: String) {
        let url = URL(fileURLWithPath: path)
        subtitles = SubtitleParser.parse(fileURL: url)
        log("[Player] 자막 로드: \(subtitles.count)개 항목")
    }

    func toggleRenderMode() {
        renderMode = (renderMode == .displayLink) ? .thread : .displayLink
    }

    // MARK: - 프레임 타이밍

    private func updateFrameTiming() {
        frameDuration = 1.0 / 30.0
        if let v = demuxer.videoStreams.first {
            let fps = av_q2d(v.frameRate)
            if fps > 0 { frameDuration = 1.0 / fps }
        }
        dropThreshold = -frameDuration * 3
        showThreshold = frameDuration * 0.5
    }

    // MARK: - 렌더러 전환

    private func startRenderer() {
        switch renderMode {
        case .displayLink:
            startDisplayLink()
        case .thread:
            startRenderThread()
        }
    }

    private func stopRenderer() {
        stopDisplayLink()
        stopRenderThread()
    }

    // MARK: - 스레드 관리

    private func startReadThread() {
        isReading = true
        readThread = Thread { [weak self] in
            self?.readLoop()
            self?.readThreadDone.signal()
        }
        readThread?.name = "iPlayer.Read"
        readThread?.qualityOfService = .userInteractive
        readThread?.start()
    }

    private func stopReadThread() {
        guard isReading else { return }
        isReading = false
        readThreadDone.wait()
        readThread = nil
    }

    private func startRenderThread() {
        guard !isRendering else { return }
        isRendering = true
        resetClock(fromPTS: currentTime)
        fpsTimerStart = CACurrentMediaTime()
        fpsCounter = 0

        renderThread = Thread { [weak self] in
            self?.renderLoop()
            self?.renderThreadDone.signal()
        }
        renderThread?.name = "iPlayer.Render"
        renderThread?.qualityOfService = .userInteractive
        renderThread?.start()
    }

    private func stopRenderThread() {
        guard isRendering else { return }
        isRendering = false
        renderThreadDone.wait()
        renderThread = nil
    }

    // MARK: - CVDisplayLink

    private func startDisplayLink() {
        guard !displayLinkRunning else { return }
        resetClock(fromPTS: currentTime)
        fpsTimerStart = CACurrentMediaTime()
        fpsCounter = 0
        uiUpdateCounter = 0

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else {
            log("[Render] CVDisplayLink 생성 실패, Thread 폴백")
            renderMode = .thread
            startRenderThread()
            return
        }
        displayLink = link

        let ptr = Unmanaged.passRetained(self).toOpaque()
        displayLinkSelfPtr = ptr
        CVDisplayLinkSetOutputCallback(link, { (_, _, _, _, _, context) -> CVReturn in
            let controller = Unmanaged<PlayerController>.fromOpaque(context!).takeUnretainedValue()
            controller.displayLinkTick()
            return kCVReturnSuccess
        }, ptr)

        CVDisplayLinkStart(link)
        displayLinkRunning = true
        log("[Render] CVDisplayLink 시작")
    }

    private func stopDisplayLink() {
        guard displayLinkRunning, let link = displayLink else { return }
        CVDisplayLinkStop(link)
        displayLinkRunning = false

        if let ptr = displayLinkSelfPtr {
            Unmanaged<PlayerController>.fromOpaque(ptr).release()
            displayLinkSelfPtr = nil
        }

        displayLink = nil
        log("[Render] CVDisplayLink 정지")
    }

    /// CVDisplayLink 콜백 - 디스플레이 vsync마다 호출 (별도 스레드)
    private func displayLinkTick() {
        guard state == .playing else { return }

        let masterClock = computeMasterClock()
        currentTime = masterClock

        // EOF 감지
        if duration > 0 && masterClock >= duration - 0.05 {
            queueLock.lock()
            let empty = frameRing.isEmpty
            queueLock.unlock()
            if empty {
                currentTime = duration
                DispatchQueue.main.async { [weak self] in
                    self?.pause()
                    self?.onTimeUpdate?(self?.duration ?? 0, self?.duration ?? 0)
                }
                return
            }
        }

        // 프레임 선택
        let frameToShow = selectFrame(masterClock: masterClock)

        // FPS 측정
        measureFPS()

        if let frame = frameToShow {
            renderedFrames += 1
            fpsCounter += 1

            if hasAudio && audioOutput.compensatedPTS > 0 {
                avSyncDrift = frame.pts - audioOutput.compensatedPTS
            }

            DispatchQueue.main.async { [weak self] in
                self?.onFrameReady?(frame)
            }
        }

        // UI 업데이트 (vsync 5회마다 ≈ ~83ms @60Hz)
        uiUpdateCounter += 1
        if uiUpdateCounter >= 5 {
            uiUpdateCounter = 0
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onTimeUpdate?(self.currentTime, self.duration)
                self.updateSubtitle()
            }
        }
    }

    // MARK: - 공통 렌더 로직

    private func computeMasterClock() -> Double {
        let clock: Double
        if hasAudio && audioOutput.compensatedPTS > 0 {
            clock = audioOutput.compensatedPTS
        } else {
            let elapsed = (CACurrentMediaTime() - playbackStartWall) * Double(playbackSpeed)
            clock = playbackStartPTS + elapsed
        }
        return min(clock, duration)
    }

    private func selectFrame(masterClock: Double) -> VideoFrame? {
        queueLock.lock()
        var frameToShow: VideoFrame?

        while let first = frameRing.first {
            let diff = first.pts - masterClock

            if diff < dropThreshold {
                frameRing.removeFirst()
                droppedFrames += 1
            } else if diff < -frameDuration {
                frameToShow = first
                frameRing.removeFirst()
                break
            } else if diff <= showThreshold {
                frameToShow = first
                frameRing.removeFirst()
                break
            } else {
                break
            }
        }
        queueLock.unlock()
        return frameToShow
    }

    private func measureFPS() {
        let now = CACurrentMediaTime()
        if now - fpsTimerStart >= 1.0 {
            currentFPS = Double(fpsCounter) / (now - fpsTimerStart)
            fpsCounter = 0
            fpsTimerStart = now
        }
    }

    private func resetClock(fromPTS pts: Double) {
        playbackStartWall = CACurrentMediaTime()
        playbackStartPTS = pts
    }

    // MARK: - Read Loop

    private func readLoop() {
        while isReading {
            seekLock.lock()
            let pendingSeek = seekRequest
            seekRequest = nil
            seekLock.unlock()

            if let target = pendingSeek {
                performSeek(to: target)
            }

            queueLock.lock()
            let queueSize = frameRing.count
            queueLock.unlock()

            if queueSize > 120 {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }

            guard let packet = demuxer.readPacket() else {
                Thread.sleep(forTimeInterval: 0.02)
                continue
            }

            defer {
                var pkt: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&pkt)
            }

            if packet.pointee.stream_index == demuxer.selectedVideoIndex {
                let frames = videoDecoder.decode(packet: packet)
                if !frames.isEmpty {
                    queueLock.lock()
                    frameRing.append(contentsOf: frames)
                    queueLock.unlock()
                }
            } else if packet.pointee.stream_index == demuxer.selectedAudioIndex {
                let buffers = audioDecoder.decode(packet: packet)
                for buf in buffers {
                    audioOutput.enqueue(buffer: buf)
                }
            }
        }
    }

    // MARK: - Render Loop (Thread 모드)

    private func renderLoop() {
        var uiCounter = 0

        while isRendering {
            guard state == .playing else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            let masterClock = computeMasterClock()
            currentTime = masterClock

            // EOF 감지
            if duration > 0 && masterClock >= duration - 0.05 {
                queueLock.lock()
                let empty = frameRing.isEmpty
                queueLock.unlock()
                if empty {
                    currentTime = duration
                    DispatchQueue.main.async { [weak self] in
                        self?.pause()
                        self?.onTimeUpdate?(self?.duration ?? 0, self?.duration ?? 0)
                    }
                    break
                }
            }

            let frameToShow = selectFrame(masterClock: masterClock)
            measureFPS()

            if let frame = frameToShow {
                renderedFrames += 1
                fpsCounter += 1

                if hasAudio && audioOutput.compensatedPTS > 0 {
                    avSyncDrift = frame.pts - audioOutput.compensatedPTS
                }

                DispatchQueue.main.async { [weak self] in
                    self?.onFrameReady?(frame)
                }
            }

            uiCounter += 1
            if uiCounter >= 3 {
                uiCounter = 0
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.onTimeUpdate?(self.currentTime, self.duration)
                    self.updateSubtitle()
                }
            }

            // 정밀 슬립
            queueLock.lock()
            let sleepTime: Double
            if let next = frameRing.first {
                let waitUntil = next.pts - masterClock
                sleepTime = max(0.0005, min(waitUntil * 0.6, frameDuration * 0.8))
            } else {
                sleepTime = 0.002
            }
            queueLock.unlock()
            Thread.sleep(forTimeInterval: sleepTime)
        }
    }

    /// read thread 내에서만 호출
    private func performSeek(to target: Double) {
        demuxer.seek(to: target)
        videoDecoder.flush()
        audioDecoder.flush()
        audioOutput.reset()

        queueLock.lock()
        frameRing.removeAll()
        queueLock.unlock()

        currentTime = target
        resetClock(fromPTS: target)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onTimeUpdate?(self.currentTime, self.duration)
        }
    }

    // MARK: - 유틸

    private func loadSubtitleAutomatic(videoPath: String) {
        let base = (videoPath as NSString).deletingPathExtension
        for ext in ["srt", "smi", "smil", "SRT", "SMI"] {
            let subPath = "\(base).\(ext)"
            if FileManager.default.fileExists(atPath: subPath) {
                loadSubtitle(path: subPath)
                return
            }
        }
    }

    private func buildMediaInfo() -> MediaInfo {
        var info = MediaInfo()
        if let v = demuxer.videoStreams.first {
            info.videoCodec = v.stream.codecName
            info.width = v.width
            info.height = v.height
            info.displayWidth = v.displayWidth
            info.displayHeight = v.displayHeight
            info.rotation = v.rotation
            info.videoBitRate = v.bitRate
            info.fps = av_q2d(v.frameRate)
        }
        if let a = demuxer.audioStreams.first {
            info.audioCodec = a.stream.codecName
            info.audioSampleRate = a.sampleRate
            info.audioChannels = a.channels
            info.audioBitRate = a.bitRate
        }
        info.hwAccelerated = videoDecoder.isHardwareAccelerated
        info.duration = duration
        return info
    }

    private func updateSubtitle() {
        let adjustedTime = currentTime + subtitleOffset
        let current = subtitles.first { entry in
            adjustedTime >= entry.startTime && adjustedTime < entry.endTime
        }
        let text = current?.text ?? ""
        if text != currentSubtitle {
            currentSubtitle = text
            onSubtitleUpdate?(text)
        }
    }
}
