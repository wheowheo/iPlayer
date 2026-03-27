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
    // 컴포넌트
    let demuxer = Demuxer()
    let videoDecoder = VideoDecoder()
    let audioDecoder = AudioDecoder()
    let audioOutput = AudioOutput()

    // 상태
    private(set) var state: PlaybackState = .idle
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var filePath: String = ""

    // 재생 설정
    var playbackSpeed: Float = 1.0 {
        didSet {
            audioOutput.playbackRate = playbackSpeed
        }
    }
    var volume: Float = 1.0 {
        didSet {
            audioOutput.volume = volume
        }
    }
    var isMuted: Bool = false {
        didSet {
            audioOutput.isMuted = isMuted
        }
    }

    // 자막
    private(set) var subtitles: [SubtitleEntry] = []
    var subtitleOffset: Double = 0
    private(set) var currentSubtitle: String = ""

    // 콜백
    var onFrameReady: ((VideoFrame) -> Void)?
    var onTimeUpdate: ((Double, Double) -> Void)?
    var onSubtitleUpdate: ((String) -> Void)?
    var onStateChange: ((PlaybackState) -> Void)?
    var onMediaInfo: ((MediaInfo) -> Void)?

    // 내부
    private var readThread: Thread?
    private var isReading = false
    private var videoFrameQueue: [VideoFrame] = []
    private let queueLock = NSLock()
    private var displayLink: CVDisplayLink?
    private var lastVideoTime: Double = 0
    private(set) var droppedFrames: Int = 0
    private(set) var renderedFrames: Int = 0
    private var fpsCounter = 0
    private var fpsTimer: Double = 0
    private(set) var currentFPS: Double = 0
    private var isSeeking = false
    private var frameStepMode = false

    // 비디오 정보
    struct MediaInfo {
        var videoCodec: String = ""
        var audioCodec: String = ""
        var width: Int32 = 0
        var height: Int32 = 0
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
            print("[Player] 파일 열기 실패")
            return
        }
        filePath = path
        duration = demuxer.duration

        // 비디오 디코더 초기화
        if demuxer.selectedVideoIndex >= 0, let fmtCtx = demuxer.formatCtx {
            guard videoDecoder.open(formatCtx: fmtCtx, streamIndex: demuxer.selectedVideoIndex) else {
                print("[Player] 비디오 디코더 열기 실패")
                return
            }
        }

        // 오디오 디코더 초기화
        if demuxer.selectedAudioIndex >= 0, let fmtCtx = demuxer.formatCtx {
            guard audioDecoder.open(formatCtx: fmtCtx, streamIndex: demuxer.selectedAudioIndex) else {
                print("[Player] 오디오 디코더 열기 실패")
                return
            }
        }

        // 같은 이름의 자막 파일 자동 로드
        loadSubtitleAutomatic(videoPath: path)

        // 미디어 정보 전달
        let info = buildMediaInfo()
        DispatchQueue.main.async { [weak self] in
            self?.onMediaInfo?(info)
        }

        play()
    }

    func play() {
        guard state != .playing else { return }

        if state == .idle || state == .stopped {
            // 오디오 출력 시작
            if demuxer.selectedAudioIndex >= 0 {
                _ = audioOutput.start()
            }
            startReadThread()
            startDisplayLink()
        } else if state == .paused {
            audioOutput.resume()
            startDisplayLink()
        }

        frameStepMode = false
        state = .playing
        onStateChange?(state)
    }

    func pause() {
        guard state == .playing else { return }
        audioOutput.pause()
        stopDisplayLink()
        state = .paused
        onStateChange?(state)
    }

    func togglePlayPause() {
        if state == .playing {
            pause()
        } else {
            play()
        }
    }

    func stop() {
        isReading = false
        readThread = nil
        stopDisplayLink()
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
        state = .stopped
        onStateChange?(state)
    }

    func seek(to seconds: Double) {
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
        if state == .playing {
            pause()
        }
        frameStepMode = true

        // 다음 프레임 하나 디코딩
        queueLock.lock()
        if let frame = videoFrameQueue.first {
            videoFrameQueue.removeFirst()
            queueLock.unlock()
            currentTime = frame.pts
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
        print("[Player] 자막 로드: \(subtitles.count)개 항목")
    }

    // MARK: - Private

    private func loadSubtitleAutomatic(videoPath: String) {
        let base = (videoPath as NSString).deletingPathExtension
        let extensions = ["srt", "smi", "smil", "SRT", "SMI"]
        for ext in extensions {
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

    private func startReadThread() {
        isReading = true
        readThread = Thread { [weak self] in
            self?.readLoop()
        }
        readThread?.name = "iPlayer.ReadThread"
        readThread?.qualityOfService = .userInteractive
        readThread?.start()
    }

    private func readLoop() {
        while isReading {
            // 큐가 너무 크면 대기
            queueLock.lock()
            let queueSize = videoFrameQueue.count
            queueLock.unlock()

            if queueSize > 60 {
                Thread.sleep(forTimeInterval: 0.005)
                continue
            }

            guard let packet = demuxer.readPacket() else {
                // EOF
                Thread.sleep(forTimeInterval: 0.01)
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

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link = link else { return }

        let opaquePtr = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, displayLinkCallback, opaquePtr)
        CVDisplayLinkStart(link)
        self.displayLink = link
    }

    private func stopDisplayLink() {
        if let link = displayLink {
            CVDisplayLinkStop(link)
            displayLink = nil
        }
    }

    fileprivate func displayTick() {
        guard state == .playing, !isSeeking else { return }

        // 오디오 PTS를 마스터 클럭으로
        let audioClock = audioOutput.currentPTS
        if audioClock > 0 {
            currentTime = audioClock
        }

        // FPS 카운터
        let now = CACurrentMediaTime()
        fpsCounter += 1
        if now - fpsTimer >= 1.0 {
            currentFPS = Double(fpsCounter) / (now - fpsTimer)
            fpsCounter = 0
            fpsTimer = now
        }

        // 비디오 프레임 표시
        queueLock.lock()
        var frameToShow: VideoFrame?

        while let first = videoFrameQueue.first {
            let diff = first.pts - currentTime
            if diff < -0.05 {
                // 너무 늦은 프레임: 드롭
                videoFrameQueue.removeFirst()
                droppedFrames += 1
            } else if diff <= 0.05 {
                // 표시할 시간
                frameToShow = first
                videoFrameQueue.removeFirst()
                break
            } else {
                // 아직 이름
                break
            }
        }
        queueLock.unlock()

        if let frame = frameToShow {
            renderedFrames += 1
            DispatchQueue.main.async { [weak self] in
                self?.onFrameReady?(frame)
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.onTimeUpdate?(self.currentTime, self.duration)
            self.updateSubtitle()
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

private func displayLinkCallback(
    displayLink: CVDisplayLink,
    inNow: UnsafePointer<CVTimeStamp>,
    inOutputTime: UnsafePointer<CVTimeStamp>,
    flagsIn: CVOptionFlags,
    flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    displayLinkContext: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx = displayLinkContext else { return kCVReturnSuccess }
    let controller = Unmanaged<PlayerController>.fromOpaque(ctx).takeUnretainedValue()
    controller.displayTick()
    return kCVReturnSuccess
}
