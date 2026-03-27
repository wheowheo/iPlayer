import Foundation
import CFFmpeg
import AppKit

enum PlaybackState {
    case idle
    case playing
    case paused
    case stopped
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

    // 스레드
    private var readThread: Thread?
    private var renderThread: Thread?
    private var isReading = false
    private var isRendering = false
    private let readThreadDone = DispatchSemaphore(value: 0)
    private let renderThreadDone = DispatchSemaphore(value: 0)

    // 프레임 큐
    private var videoFrameQueue: [VideoFrame] = []
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
            startRenderThread()
        } else if state == .paused {
            if hasAudio { audioOutput.resume() }
            resetClock(fromPTS: currentTime)
            startRenderThread()
        }

        state = .playing
        onStateChange?(state)
    }

    func pause() {
        guard state == .playing else { return }
        if hasAudio { audioOutput.pause() }
        stopRenderThread()
        state = .paused
        onStateChange?(state)
    }

    func togglePlayPause() {
        if state == .playing { pause() }
        else { play() }
    }

    func stop() {
        // 스레드를 먼저 확실히 종료한 후 리소스 해제
        stopRenderThread()
        stopReadThread()

        audioOutput.stop()
        videoDecoder.close()
        audioDecoder.close()
        demuxer.close()

        queueLock.lock()
        videoFrameQueue.removeAll()
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

        // seek 요청을 read thread에 위임 (thread-safe)
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
        if let frame = videoFrameQueue.first {
            videoFrameQueue.removeFirst()
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

    private func resetClock(fromPTS pts: Double) {
        playbackStartWall = CACurrentMediaTime()
        playbackStartPTS = pts
    }

    // MARK: - Read Loop

    private func readLoop() {
        while isReading {
            // seek 요청 처리 (이 스레드에서만 demuxer/decoder 접근)
            seekLock.lock()
            let pendingSeek = seekRequest
            seekRequest = nil
            seekLock.unlock()

            if let target = pendingSeek {
                performSeek(to: target)
            }

            // 큐 배압 제어
            queueLock.lock()
            let queueSize = videoFrameQueue.count
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
                    videoFrameQueue.append(contentsOf: frames)
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

    /// read thread 내에서만 호출 - thread safe
    private func performSeek(to target: Double) {
        demuxer.seek(to: target)
        videoDecoder.flush()
        audioDecoder.flush()
        audioOutput.reset()

        queueLock.lock()
        videoFrameQueue.removeAll()
        queueLock.unlock()

        currentTime = target
        resetClock(fromPTS: target)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onTimeUpdate?(self.currentTime, self.duration)
        }
    }

    // MARK: - Render Loop

    private func renderLoop() {
        while isRendering {
            guard state == .playing else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            // 마스터 클럭 계산
            let clock: Double
            if hasAudio && audioOutput.currentPTS > 0 {
                clock = audioOutput.currentPTS
            } else {
                let elapsed = (CACurrentMediaTime() - playbackStartWall) * Double(playbackSpeed)
                clock = playbackStartPTS + elapsed
            }
            let masterClock = min(clock, duration)
            currentTime = masterClock

            // EOF
            if duration > 0 && masterClock >= duration - 0.05 {
                queueLock.lock()
                let empty = videoFrameQueue.isEmpty
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

            // 프레임 선택
            queueLock.lock()
            var frameToShow: VideoFrame?

            while let first = videoFrameQueue.first {
                let diff = first.pts - masterClock
                if diff < -0.1 {
                    videoFrameQueue.removeFirst()
                    droppedFrames += 1
                } else if diff <= 0.02 {
                    frameToShow = first
                    videoFrameQueue.removeFirst()
                    break
                } else {
                    break
                }
            }
            queueLock.unlock()

            // FPS 측정
            let now = CACurrentMediaTime()
            if now - fpsTimerStart >= 1.0 {
                currentFPS = Double(fpsCounter) / (now - fpsTimerStart)
                fpsCounter = 0
                fpsTimerStart = now
            }

            if let frame = frameToShow {
                renderedFrames += 1
                fpsCounter += 1
                DispatchQueue.main.async { [weak self] in
                    self?.onFrameReady?(frame)
                }
            }

            // UI 업데이트
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onTimeUpdate?(self.currentTime, self.duration)
                self.updateSubtitle()
            }

            // 슬립
            queueLock.lock()
            let sleepTime: Double
            if let next = videoFrameQueue.first {
                let wait = next.pts - masterClock
                sleepTime = max(0.001, min(wait * 0.7, 0.016))
            } else {
                sleepTime = 0.003
            }
            queueLock.unlock()
            Thread.sleep(forTimeInterval: sleepTime)
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
