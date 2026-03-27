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

    private var readThread: Thread?
    private var renderThread: Thread?
    private var isReading = false
    private var isRendering = false
    private var videoFrameQueue: [VideoFrame] = []
    private let queueLock = NSLock()
    private(set) var droppedFrames: Int = 0
    private(set) var renderedFrames: Int = 0
    private var fpsCounter = 0
    private var fpsTimerStart: Double = 0
    private(set) var currentFPS: Double = 0
    private var isSeeking = false

    // 재생 시작 기준
    private var playbackStartTime: Double = 0  // CACurrentMediaTime 기준
    private var playbackStartPTS: Double = 0   // 시작 PTS
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
            } else {
                log("[Player] 오디오 디코더 열기 실패 - 오디오 없이 재생")
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
            if hasAudio {
                _ = audioOutput.start()
            }
            startReadThread()
            // 초기 버퍼링: 프레임이 좀 쌓일 때까지 대기
            Thread.sleep(forTimeInterval: 0.1)
            startRenderThread()
        } else if state == .paused {
            if hasAudio {
                audioOutput.resume()
            }
            // 일시정지에서 복귀: 시간 기준점 재설정
            playbackStartTime = CACurrentMediaTime()
            playbackStartPTS = currentTime
            startRenderThread()
        }

        state = .playing
        onStateChange?(state)
    }

    func pause() {
        guard state == .playing else { return }
        if hasAudio {
            audioOutput.pause()
        }
        isRendering = false
        state = .paused
        onStateChange?(state)
    }

    func togglePlayPause() {
        if state == .playing { pause() }
        else { play() }
    }

    func stop() {
        isReading = false
        isRendering = false
        readThread = nil
        renderThread = nil

        audioOutput.stop()
        videoDecoder.close()
        audioDecoder.close()
        demuxer.close()

        queueLock.lock()
        videoFrameQueue.removeAll()
        queueLock.unlock()

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
        isSeeking = true

        demuxer.seek(to: target)
        videoDecoder.flush()
        audioDecoder.flush()
        audioOutput.reset()

        queueLock.lock()
        videoFrameQueue.removeAll()
        queueLock.unlock()

        currentTime = target
        playbackStartTime = CACurrentMediaTime()
        playbackStartPTS = target
        isSeeking = false

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onTimeUpdate?(self.currentTime, self.duration)
        }
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

    func loadSubtitle(path: String) {
        let url = URL(fileURLWithPath: path)
        subtitles = SubtitleParser.parse(fileURL: url)
        log("[Player] 자막 로드: \(subtitles.count)개 항목")
    }

    // MARK: - Private

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

    // MARK: - Read Thread (패킷 읽기 + 디코딩)

    private func startReadThread() {
        isReading = true
        readThread = Thread { [weak self] in
            self?.readLoop()
        }
        readThread?.name = "iPlayer.Read"
        readThread?.qualityOfService = .userInteractive
        readThread?.start()
    }

    private func readLoop() {
        while isReading {
            queueLock.lock()
            let queueSize = videoFrameQueue.count
            queueLock.unlock()

            if queueSize > 120 {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }

            guard let packet = demuxer.readPacket() else {
                // EOF 도달
                Thread.sleep(forTimeInterval: 0.05)
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

    // MARK: - Render Thread (PTS 기반 프레임 표시)

    private func startRenderThread() {
        isRendering = true

        // 시간 기준점 설정
        queueLock.lock()
        if let firstFrame = videoFrameQueue.first {
            playbackStartPTS = firstFrame.pts
        } else {
            playbackStartPTS = currentTime
        }
        queueLock.unlock()
        playbackStartTime = CACurrentMediaTime()
        fpsTimerStart = playbackStartTime
        fpsCounter = 0

        renderThread = Thread { [weak self] in
            self?.renderLoop()
        }
        renderThread?.name = "iPlayer.Render"
        renderThread?.qualityOfService = .userInteractive
        renderThread?.start()
    }

    private func renderLoop() {
        while isRendering {
            guard state == .playing, !isSeeking else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            // 현재 재생 시각 계산
            let clock: Double
            if hasAudio && audioOutput.currentPTS > 0 {
                // 오디오 마스터 클럭
                clock = audioOutput.currentPTS
            } else {
                // 벽시계 기반 클럭 (오디오 없을 때)
                let elapsed = (CACurrentMediaTime() - playbackStartTime) * Double(playbackSpeed)
                clock = playbackStartPTS + elapsed
            }
            let masterClock = min(clock, duration)
            currentTime = masterClock

            // EOF 체크
            if duration > 0 && masterClock >= duration {
                currentTime = duration
                DispatchQueue.main.async { [weak self] in
                    self?.pause()
                    self?.onTimeUpdate?(self?.duration ?? 0, self?.duration ?? 0)
                }
                break
            }

            // 비디오 프레임 처리
            queueLock.lock()
            var frameToShow: VideoFrame?

            while let first = videoFrameQueue.first {
                let diff = first.pts - masterClock
                if diff < -0.1 {
                    // 늦은 프레임: 드롭
                    videoFrameQueue.removeFirst()
                    droppedFrames += 1
                } else if diff <= 0.02 {
                    // 표시할 타이밍
                    frameToShow = first
                    videoFrameQueue.removeFirst()
                    break
                } else {
                    // 아직 이른 프레임 - 대기
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

            // 시간 업데이트 (매 프레임 아니라 주기적으로)
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.onTimeUpdate?(self.currentTime, self.duration)
                self.updateSubtitle()
            }

            // 다음 프레임까지 슬립 (CPU 절약, ~60fps 기준)
            // 큐에 다음 프레임이 있으면 그 PTS까지, 없으면 짧게 대기
            queueLock.lock()
            let sleepTime: Double
            if let next = videoFrameQueue.first {
                let waitUntil = next.pts - masterClock
                sleepTime = max(0.001, min(waitUntil * 0.8, 0.016))
            } else {
                sleepTime = 0.002
            }
            queueLock.unlock()
            Thread.sleep(forTimeInterval: sleepTime)
        }
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
