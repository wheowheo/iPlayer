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

enum InputSource {
    case file
    case camera
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
    var onBuffering: ((Bool) -> Void)?
    var onInputSourceChange: ((InputSource) -> Void)?

    // 입력 소스
    private(set) var inputSource: InputSource = .file
    let cameraController = CameraController()

    // 버퍼링 상태
    private(set) var isBuffering = false
    private var bufferingStartTime: Double = 0

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

    // --- 스레드 ---
    // demux 스레드: 패킷 읽기 + 오디오 디코딩
    private var demuxThread: Thread?
    private var isDemuxing = false
    private let demuxThreadDone = DispatchSemaphore(value: 0)

    // 비디오 디코딩 전용 스레드
    private var decodeThread: Thread?
    private var isDecoding = false
    private let decodeThreadDone = DispatchSemaphore(value: 0)

    // 렌더 스레드 (Thread 모드)
    private var renderThread: Thread?
    private var isRendering = false
    private let renderThreadDone = DispatchSemaphore(value: 0)

    // CVDisplayLink
    private var displayLink: CVDisplayLink?
    private var displayLinkRunning = false
    private var displayLinkSelfPtr: UnsafeMutableRawPointer?

    // --- 비디오 패킷 큐 ---
    private var videoPacketQueue: [UnsafeMutablePointer<AVPacket>] = []
    private let packetQueueLock = NSLock()
    private let packetQueueSemaphore = DispatchSemaphore(value: 0)
    private let maxPacketQueueSize = 120

    // 프레임 큐 (원형 버퍼)
    private var frameRing = FrameRingBuffer(capacity: 256)
    private let queueLock = NSLock()

    // 디코더 접근 동기화 (flush ↔ decode 경합 방지)
    private let videoDecoderLock = NSLock()

    // seek 제어
    private var seekRequest: Double? = nil
    private let seekLock = NSLock()
    private var seekTargetPTS: Double = -1
    private var frameSkipForSpeed: Int = 0  // 고속 패킷 스킵 카운터

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

    /// 프레임 큐 깊이 (외부에서 자원 경합 판단용)
    var frameQueueDepth: Int {
        queueLock.lock()
        let d = frameRing.count
        queueLock.unlock()
        return d
    }

    // UI 업데이트 카운터
    private var uiUpdateCounter = 0

    // 프레임 드롭 디버거
    let dropDebugger = FrameDropDebugger()

    // 프리버퍼링 완료 시그널
    private let prebufferReady = DispatchSemaphore(value: 0)
    private var prebufferTarget: Int = 15  // 프리버퍼링 목표 프레임 수

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

        // EOF에서 일시정지된 상태 → 처음부터 다시 재생
        if state == .paused && demuxEOF && duration > 0 && currentTime >= duration - 0.5 {
            let path = filePath
            stop()
            openFile(path: path)
            return
        }

        if state == .idle || state == .stopped {
            if hasAudio { _ = audioOutput.start() }
            startDemuxThread()
            startDecodeThread()
            // 적응적 프리버퍼링: 목표 프레임 수만큼 채운 후 렌더 시작
            _ = prebufferReady.wait(timeout: .now() + 1.0)
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
        if inputSource == .camera {
            stopCamera()
            return
        }
        stopRenderer()
        stopDecodeThread()
        stopDemuxThread()
        flushPacketQueue()

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
        seekTargetPTS = -1

        currentTime = 0
        droppedFrames = 0
        renderedFrames = 0
        subtitles.removeAll()
        currentSubtitle = ""
        hasAudio = false
        demuxEOF = false
        lastAudioPTS = 0
        audioStallTime = 0
        isBuffering = false
        dropDebugger.reset()
        state = .stopped
        onStateChange?(state)
    }

    func seek(to seconds: Double) {
        guard demuxer.formatCtx != nil else { return }
        let target = max(0, min(seconds, duration))

        // EOF 상태에서 seek → 재생 재개 필요
        let wasEOF = (state == .paused && demuxEOF)

        seekLock.lock()
        seekRequest = target
        seekLock.unlock()

        if wasEOF {
            play()
        }
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

    // MARK: - 카메라 입력

    func startCamera(deviceID: String? = nil) {
        stop()
        inputSource = .camera

        cameraController.onFrameReady = { [weak self] pixelBuffer, w, h in
            guard let self = self else { return }
            nonisolated(unsafe) let buf = pixelBuffer
            DispatchQueue.main.async {
                let frame = VideoFrame(pixelBuffer: buf, pts: CACurrentMediaTime(),
                                       width: w, height: h)
                self.onFrameReady?(frame)
            }
        }

        guard cameraController.start(deviceID: deviceID) else {
            inputSource = .file
            return
        }

        state = .playing
        onStateChange?(state)
        onInputSourceChange?(.camera)

        let info = MediaInfo(
            videoCodec: "Camera",
            width: 1920, height: 1080,
            displayWidth: 1920, displayHeight: 1080,
            hwAccelerated: true, duration: 0
        )
        DispatchQueue.main.async { [weak self] in
            self?.onMediaInfo?(info)
        }
    }

    func stopCamera() {
        cameraController.stop()
        cameraController.onFrameReady = nil

        queueLock.lock()
        frameRing.removeAll()
        queueLock.unlock()

        currentTime = 0
        duration = 0
        inputSource = .file
        state = .stopped

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onStateChange?(self.state)
            self.onTimeUpdate?(0, 0)
            self.onInputSourceChange?(.file)
        }
    }

    /// 카메라 종료 시 화면 클리어 콜백
    var onCameraStopped: (() -> Void)?

    // MARK: - 프레임 타이밍

    private func updateFrameTiming() {
        frameDuration = 1.0 / 30.0
        if let v = demuxer.videoStreams.first {
            let fps = av_q2d(v.frameRate)
            if fps > 0 { frameDuration = 1.0 / fps }
        }
        dropThreshold = -frameDuration * 3
        showThreshold = frameDuration * 0.5
        dropDebugger.setFrameDuration(frameDuration)

        // 60fps 이상이면 프리버퍼 목표를 높임
        if frameDuration <= 1.0 / 50.0 {
            prebufferTarget = 30  // 60fps: 0.5초
        } else {
            prebufferTarget = 15  // 30fps: 0.5초
        }
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

    // MARK: - Demux 스레드

    private func startDemuxThread() {
        isDemuxing = true
        demuxThread = Thread { [weak self] in
            self?.demuxLoop()
            self?.demuxThreadDone.signal()
        }
        demuxThread?.name = "iPlayer.Demux"
        demuxThread?.qualityOfService = .userInteractive
        demuxThread?.start()
    }

    private func stopDemuxThread() {
        guard isDemuxing else { return }
        isDemuxing = false
        packetQueueSemaphore.signal() // decode 스레드가 대기 중일 수 있으므로 깨움
        demuxThreadDone.wait()
        demuxThread = nil
    }

    // MARK: - Video Decode 스레드

    private func startDecodeThread() {
        isDecoding = true
        decodeThread = Thread { [weak self] in
            self?.videoDecodeLoop()
            self?.decodeThreadDone.signal()
        }
        decodeThread?.name = "iPlayer.VideoDecode"
        decodeThread?.qualityOfService = .userInteractive
        decodeThread?.start()
    }

    private func stopDecodeThread() {
        guard isDecoding else { return }
        isDecoding = false
        packetQueueSemaphore.signal()
        decodeThreadDone.wait()
        decodeThread = nil
    }

    // MARK: - Render 스레드 (Thread 모드)

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
        displayLinkRunning = false
        CVDisplayLinkStop(link)
        displayLink = nil

        if let ptr = displayLinkSelfPtr {
            displayLinkSelfPtr = nil
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                Unmanaged<PlayerController>.fromOpaque(ptr).release()
            }
        }

        log("[Render] CVDisplayLink 정지")
    }

    /// CVDisplayLink 콜백
    private func displayLinkTick() {
        guard displayLinkRunning, state == .playing else { return }

        dropDebugger.recordRenderTick()

        let masterClock = computeMasterClock()
        currentTime = masterClock

        if checkEOF(masterClock: masterClock) { return }

        // 버퍼링 감지: 프레임 큐가 비어있고 EOF 아님
        queueLock.lock()
        let queueEmpty = frameRing.isEmpty
        let qd = frameRing.count
        queueLock.unlock()

        if queueEmpty && !demuxEOF {
            if !isBuffering {
                isBuffering = true
                bufferingStartTime = CACurrentMediaTime()
                if hasAudio { audioOutput.pause() }
                DispatchQueue.main.async { [weak self] in self?.onBuffering?(true) }
            }
            // 버퍼링 중: 클럭 정지, 프레임 대기
            return
        }

        if isBuffering && qd >= 5 {
            // 버퍼 충분 → 재개
            isBuffering = false
            if hasAudio { audioOutput.resume() }
            resetClock(fromPTS: currentTime)
            DispatchQueue.main.async { [weak self] in self?.onBuffering?(false) }
        }

        let frameToShow = selectFrame(masterClock: masterClock)
        measureFPS()

        if let frame = frameToShow {
            renderedFrames += 1
            fpsCounter += 1

            if hasAudio && audioOutput.compensatedPTS > 0 {
                avSyncDrift = frame.pts - audioOutput.compensatedPTS
            }

            let token = dropDebugger.dispatchBegin()
            let clock = masterClock
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.dropDebugger.dispatchEnd(token: token, playbackTime: clock, masterClock: clock, queueDepth: qd)
                self.onFrameReady?(frame)
            }
        }

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

    // 오디오 클럭이 멈춘 것을 감지하기 위한 변수
    private var lastAudioPTS: Double = 0
    private var audioStallTime: Double = 0

    private func computeMasterClock() -> Double {
        let clock: Double
        if hasAudio && audioOutput.compensatedPTS > 0 {
            let audioPTS = audioOutput.compensatedPTS
            let now = CACurrentMediaTime()

            // 오디오 PTS가 0.5초 이상 변화 없으면 오디오 끝난 것으로 판단 → 벽시계 전환
            if abs(audioPTS - lastAudioPTS) < 0.001 {
                if audioStallTime == 0 { audioStallTime = now }
                if now - audioStallTime > 0.5 {
                    // 오디오 종료 → 벽시계 기반 클럭
                    let elapsed = (now - playbackStartWall) * Double(playbackSpeed)
                    clock = playbackStartPTS + elapsed
                    return min(clock, duration)
                }
            } else {
                audioStallTime = 0
                lastAudioPTS = audioPTS
            }

            clock = audioPTS
        } else {
            let elapsed = (CACurrentMediaTime() - playbackStartWall) * Double(playbackSpeed)
            clock = playbackStartPTS + elapsed
        }
        return min(clock, duration)
    }

    private func checkEOF(masterClock: Double) -> Bool {
        let clockNearEnd = duration > 0 && masterClock >= duration - 0.1
        let allDrained = demuxEOF && videoPacketQueueSize == 0

        queueLock.lock()
        let frameEmpty = frameRing.isEmpty
        queueLock.unlock()

        guard (clockNearEnd && frameEmpty) || (allDrained && frameEmpty) else { return false }

        currentTime = duration
        DispatchQueue.main.async { [weak self] in
            self?.pause()
            self?.onTimeUpdate?(self?.duration ?? 0, self?.duration ?? 0)
        }
        return true
    }

    private func selectFrame(masterClock: Double) -> VideoFrame? {
        queueLock.lock()
        let depth = frameRing.count
        var frameToShow: VideoFrame?

        let speed = Double(playbackSpeed)
        let speedFactor = max(1.0, speed)
        let effectiveDrop = dropThreshold * speedFactor
        let effectiveShow = showThreshold * speedFactor

        dropDebugger.recordQueueDepth(depth, playbackTime: masterClock, masterClock: masterClock)

        if speed > 2.0 {
            // 고속 모드: 클럭 이전 프레임은 스킵, 클럭에 가장 가까운 프레임 표시
            while let first = frameRing.first {
                let diff = first.pts - masterClock
                if diff > effectiveShow {
                    // 아직 미래의 프레임 → 대기
                    break
                }
                // 클럭 이전 또는 근접 프레임
                frameRing.removeFirst()
                frameToShow = first  // 항상 최신 후보로 갱신
                if diff >= -frameDuration * speedFactor {
                    // 충분히 가까움 → 이 프레임 표시
                    break
                }
            }
        } else {
            // 일반 모드: 정밀 동기화
            while let first = frameRing.first {
                let diff = first.pts - masterClock

                if diff < effectiveDrop {
                    frameRing.removeFirst()
                    droppedFrames += 1
                    dropDebugger.recordLateDrop(
                        framePTS: first.pts, masterClock: masterClock,
                        diff: diff, queueDepth: depth
                    )
                } else if diff < -frameDuration {
                    frameToShow = first
                    frameRing.removeFirst()
                    break
                } else if diff <= effectiveShow {
                    frameToShow = first
                    frameRing.removeFirst()
                    break
                } else {
                    break
                }
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

    // MARK: - 비디오 패킷 큐 관리

    private func enqueueVideoPacket(_ packet: UnsafeMutablePointer<AVPacket>) {
        let clone = av_packet_clone(packet)!
        packetQueueLock.lock()
        videoPacketQueue.append(clone)
        packetQueueLock.unlock()
        packetQueueSemaphore.signal()
    }

    private func dequeueVideoPacket() -> UnsafeMutablePointer<AVPacket>? {
        packetQueueLock.lock()
        let packet = videoPacketQueue.isEmpty ? nil : videoPacketQueue.removeFirst()
        packetQueueLock.unlock()
        return packet
    }

    private func flushPacketQueue() {
        packetQueueLock.lock()
        for pkt in videoPacketQueue {
            var p: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&p)
        }
        videoPacketQueue.removeAll()
        packetQueueLock.unlock()
    }

    private var videoPacketQueueSize: Int {
        packetQueueLock.lock()
        let size = videoPacketQueue.count
        packetQueueLock.unlock()
        return size
    }

    // EOF 플래그
    private var demuxEOF = false

    // MARK: - Demux Loop

    private func demuxLoop() {
        demuxEOF = false

        while isDemuxing {
            // seek 요청 처리
            seekLock.lock()
            let pendingSeek = seekRequest
            seekRequest = nil
            seekLock.unlock()

            if let target = pendingSeek {
                performSeek(to: target)
            }

            // 이미 EOF 도달 → 대기
            if demuxEOF {
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }

            guard let packet = demuxer.readPacket() else {
                // EOF: 디코더에 flush 신호 전송
                demuxEOF = true
                let flushPkt = av_packet_alloc()!
                flushPkt.pointee.data = nil
                flushPkt.pointee.size = 0
                packetQueueLock.lock()
                videoPacketQueue.append(flushPkt)
                packetQueueLock.unlock()
                packetQueueSemaphore.signal()
                log("[Demux] EOF 도달")
                continue
            }

            if packet.pointee.stream_index == demuxer.selectedAudioIndex {
                let buffers = audioDecoder.decode(packet: packet)
                for buf in buffers {
                    // seek 후: 타겟 이전 오디오를 버려 클럭 오염 방지
                    if seekTargetPTS >= 0 {
                        if buf.pts < seekTargetPTS - 0.5 { continue }
                        seekTargetPTS = -1  // 타겟 도달, 필터 해제
                    }
                    audioOutput.enqueue(buffer: buf)
                }
                var pkt: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&pkt)
            } else if packet.pointee.stream_index == demuxer.selectedVideoIndex {
                let speed = playbackSpeed
                let isKeyframe = (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0

                // 3배속 초과: 키프레임만 디코딩
                if speed > 3.0 && !isKeyframe {
                    var pkt: UnsafeMutablePointer<AVPacket>? = packet
                    av_packet_free(&pkt)
                    continue
                }

                // 2~3배속: 2프레임 중 1프레임만 디코딩 (키프레임은 항상 유지)
                if speed > 2.0 && speed <= 3.0 && !isKeyframe {
                    frameSkipForSpeed += 1
                    if frameSkipForSpeed % 2 != 0 {
                        var pkt: UnsafeMutablePointer<AVPacket>? = packet
                        av_packet_free(&pkt)
                        continue
                    }
                }

                // 배압: 큐 만차 시
                if videoPacketQueueSize > maxPacketQueueSize {
                    if speed > 2.5 {
                        // 초고속: 드롭하여 오디오 스타베이션 방지
                        var pkt: UnsafeMutablePointer<AVPacket>? = packet
                        av_packet_free(&pkt)
                        continue
                    }
                    // 대기 (seek 요청 시 즉시 탈출)
                    while isDemuxing && videoPacketQueueSize > maxPacketQueueSize {
                        seekLock.lock()
                        let hasPendingSeek = seekRequest != nil
                        seekLock.unlock()
                        if hasPendingSeek { break }
                        dropDebugger.recordBackpressure()
                        Thread.sleep(forTimeInterval: 0.002)
                    }
                }

                enqueueVideoPacket(packet)
                var pkt: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&pkt)
            } else {
                var pkt: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&pkt)
            }
        }
    }

    // MARK: - Video Decode Loop

    private func videoDecodeLoop() {
        var prebufferSignaled = false

        while isDecoding {
            // 세마포어 대기 (패킷이 들어올 때 깨어남)
            _ = packetQueueSemaphore.wait(timeout: .now() + 0.1)
            guard isDecoding else { break }

            // seek 중이면 디코드 스킵
            seekLock.lock()
            let seeking = seekRequest != nil
            seekLock.unlock()
            if seeking { continue }

            guard let packet = dequeueVideoPacket() else { continue }
            defer {
                var pkt: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&pkt)
            }

            // flush 패킷 (EOF) → 디코더 드레인
            let isFlush = packet.pointee.data == nil && packet.pointee.size == 0
            if isFlush {
                videoDecoderLock.lock()
                let remaining = videoDecoder.drain()
                videoDecoderLock.unlock()
                if !remaining.isEmpty {
                    queueLock.lock()
                    for frame in remaining { frameRing.append(frame) }
                    queueLock.unlock()
                }
                continue
            }

            // 프레임 큐가 꽉 차면 대기
            while isDecoding {
                queueLock.lock()
                let full = frameRing.isFull
                queueLock.unlock()
                if !full { break }
                Thread.sleep(forTimeInterval: 0.001)
            }

            dropDebugger.decodeBegin()
            videoDecoderLock.lock()
            let frames = videoDecoder.decode(packet: packet)
            videoDecoderLock.unlock()
            queueLock.lock()
            let qd = frameRing.count
            queueLock.unlock()
            dropDebugger.decodeEnd(playbackTime: currentTime, masterClock: currentTime, queueDepth: qd)

            if !frames.isEmpty {
                queueLock.lock()
                for frame in frames {
                    frameRing.append(frame)
                }
                let currentDepth = frameRing.count
                queueLock.unlock()

                // 프리버퍼링 목표 달성 시 시그널
                if !prebufferSignaled && currentDepth >= prebufferTarget {
                    prebufferSignaled = true
                    prebufferReady.signal()
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

            dropDebugger.recordRenderTick()

            let masterClock = computeMasterClock()
            currentTime = masterClock

            if checkEOF(masterClock: masterClock) { continue }

            // 버퍼링 감지
            queueLock.lock()
            let queueEmpty = frameRing.isEmpty
            let qd = frameRing.count
            queueLock.unlock()

            if queueEmpty && !demuxEOF {
                if !isBuffering {
                    isBuffering = true
                    bufferingStartTime = CACurrentMediaTime()
                    if hasAudio { audioOutput.pause() }
                    DispatchQueue.main.async { [weak self] in self?.onBuffering?(true) }
                }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            if isBuffering && qd >= 5 {
                isBuffering = false
                if hasAudio { audioOutput.resume() }
                resetClock(fromPTS: currentTime)
                DispatchQueue.main.async { [weak self] in self?.onBuffering?(false) }
            }

            let frameToShow = selectFrame(masterClock: masterClock)
            measureFPS()

            if let frame = frameToShow {
                renderedFrames += 1
                fpsCounter += 1

                if hasAudio && audioOutput.compensatedPTS > 0 {
                    avSyncDrift = frame.pts - audioOutput.compensatedPTS
                }

                let token = dropDebugger.dispatchBegin()
                let clock = masterClock
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.dropDebugger.dispatchEnd(token: token, playbackTime: clock, masterClock: clock, queueDepth: qd)
                    self.onFrameReady?(frame)
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

    /// demux 스레드에서만 호출
    private func performSeek(to target: Double) {
        // EOF 및 stall 상태 리셋
        demuxEOF = false
        lastAudioPTS = 0
        audioStallTime = 0

        // 패킷 큐 플러시 (잔여 flush 패킷 포함)
        flushPacketQueue()

        // seek 타겟 이전 오디오를 필터링하기 위해 기록
        seekTargetPTS = target

        demuxer.seek(to: target)
        videoDecoderLock.lock()
        videoDecoder.flush()
        videoDecoderLock.unlock()
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
