import Foundation
import AudioToolbox

final class AudioOutput {
    private var audioQueue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef?] = []
    private let bufferCount = 3
    private let bufferSize = 4096 * 4  // ~21ms at 48kHz stereo float32

    private var ringBuffer = RingBuffer(capacity: 8 * 1024 * 1024)
    private let lock = NSLock()

    var volume: Float = 1.0 {
        didSet {
            if let queue = audioQueue {
                AudioQueueSetParameter(queue, kAudioQueueParam_Volume, Float32(isMuted ? 0 : volume))
            }
        }
    }
    var isMuted = false {
        didSet {
            if let queue = audioQueue {
                AudioQueueSetParameter(queue, kAudioQueueParam_Volume, isMuted ? 0 : Float32(volume))
            }
        }
    }

    // PTS 추적
    private(set) var currentPTS: Double = 0
    private var ptsQueue: [(byteOffset: Int, pts: Double)] = []
    private var totalBytesConsumed: Int = 0
    private var totalBytesWritten: Int = 0
    private let bytesPerSecond: Double = 48000 * 2 * 4

    // AudioQueue 내부 버퍼 레이턴시 보상
    // bufferCount개의 버퍼가 대기 중이고, 콜백에서 1개를 채우는 시점 기준
    // 실제 하드웨어 출력까지 약 2버퍼분의 지연이 있음
    private var queueLatency: Double {
        return Double(bufferCount - 1) * Double(bufferSize) / bytesPerSecond
    }

    // 채널별 오디오 레벨 (RMS, 0.0~1.0)
    private(set) var levelL: Float = 0
    private(set) var levelR: Float = 0
    private(set) var peakL: Float = 0
    private(set) var peakR: Float = 0
    private var _displayPCM: [Float] = []

    /// 스레드 세이프하게 디스플레이 데이터 취득
    func getDisplayData() -> (levelL: Float, levelR: Float, peakL: Float, peakR: Float, pcm: [Float]) {
        lock.lock()
        let result = (levelL, levelR, peakL, peakR, _displayPCM)
        lock.unlock()
        return result
    }

    var playbackRate: Float = 1.0 {
        didSet {
            if let queue = audioQueue {
                AudioQueueSetParameter(queue, kAudioQueueParam_PlayRate, Float32(playbackRate))
            }
        }
    }

    /// 레이턴시 보상된 현재 오디오 재생 시각
    var compensatedPTS: Double {
        let raw = currentPTS
        guard raw > 0 else { return 0 }
        return max(0, raw - queueLatency)
    }

    func start() -> Bool {
        var format = AudioStreamBasicDescription(
            mSampleRate: 48000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let callbackPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewOutput(
            &format,
            audioQueueOutputCallback,
            callbackPointer,
            nil, nil, 0,
            &audioQueue
        )

        guard status == noErr, let queue = audioQueue else {
            log("[AudioOutput] AudioQueue 생성 실패: \(status)")
            return false
        }

        var enableTimePitch: UInt32 = 1
        AudioQueueSetProperty(queue, kAudioQueueProperty_EnableTimePitch,
                              &enableTimePitch, UInt32(MemoryLayout<UInt32>.size))
        AudioQueueSetParameter(queue, kAudioQueueParam_PlayRate, Float32(playbackRate))
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, Float32(volume))

        for _ in 0..<bufferCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, UInt32(bufferSize), &buffer)
            if let buffer = buffer {
                memset(buffer.pointee.mAudioData, 0, bufferSize)
                buffer.pointee.mAudioDataByteSize = UInt32(bufferSize)
                buffers.append(buffer)
                AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            }
        }

        let startStatus = AudioQueueStart(queue, nil)
        if startStatus != noErr {
            log("[AudioOutput] AudioQueue 시작 실패: \(startStatus)")
            return false
        }

        log("[AudioOutput] 시작됨 (레이턴시 보상: \(String(format: "%.1f", queueLatency * 1000))ms)")
        return true
    }

    func enqueue(buffer: AudioBuffer) {
        // 링버퍼에 공간이 부족하면 대기 (데이터 유실 방지)
        let needed = buffer.data.count
        for _ in 0..<100 {
            lock.lock()
            let free = ringBuffer.freeBytes
            lock.unlock()
            if free >= needed { break }
            Thread.sleep(forTimeInterval: 0.005)
        }

        lock.lock()
        ptsQueue.append((byteOffset: totalBytesWritten, pts: buffer.pts))
        while ptsQueue.count > 500 {
            ptsQueue.removeFirst()
        }
        totalBytesWritten += buffer.data.count
        ringBuffer.write(buffer.data)
        lock.unlock()
    }

    func stop() {
        if let queue = audioQueue {
            AudioQueueStop(queue, true)
            for buffer in buffers {
                if let buf = buffer {
                    AudioQueueFreeBuffer(queue, buf)
                }
            }
            AudioQueueDispose(queue, true)
            audioQueue = nil
        }
        buffers.removeAll()
        lock.lock()
        ringBuffer.reset()
        ptsQueue.removeAll()
        totalBytesConsumed = 0
        totalBytesWritten = 0
        currentPTS = 0
        levelL = 0; levelR = 0; peakL = 0; peakR = 0
        _displayPCM = []
        lock.unlock()
    }

    func pause() {
        if let queue = audioQueue {
            AudioQueuePause(queue)
        }
    }

    func resume() {
        if let queue = audioQueue {
            AudioQueueStart(queue, nil)
        }
    }

    func reset() {
        lock.lock()
        ringBuffer.reset()
        ptsQueue.removeAll()
        totalBytesConsumed = 0
        totalBytesWritten = 0
        currentPTS = 0
        levelL = 0; levelR = 0; peakL = 0; peakR = 0
        _displayPCM = []
        lock.unlock()
    }

    /// ring buffer에 쌓인 오디오 데이터량 (초 단위)
    var bufferedDuration: Double {
        lock.lock()
        let bytes = ringBuffer.availableBytes
        lock.unlock()
        return Double(bytes) / bytesPerSecond
    }

    fileprivate func fillBuffer(_ buffer: AudioQueueBufferRef) {
        lock.lock()
        let available = ringBuffer.availableBytes
        let toRead = min(available, bufferSize)

        if toRead > 0 {
            let ptr = buffer.pointee.mAudioData.assumingMemoryBound(to: UInt8.self)
            ringBuffer.read(into: ptr, count: toRead)
            buffer.pointee.mAudioDataByteSize = UInt32(toRead)

            totalBytesConsumed += toRead
            updateCurrentPTS()
            computeDisplayData(from: buffer.pointee.mAudioData, byteCount: toRead)
        } else {
            memset(buffer.pointee.mAudioData, 0, bufferSize)
            buffer.pointee.mAudioDataByteSize = UInt32(bufferSize)
            levelL *= 0.85; levelR *= 0.85
            peakL *= 0.95; peakR *= 0.95
        }
        lock.unlock()
    }

    private func computeDisplayData(from audioData: UnsafeMutableRawPointer, byteCount: Int) {
        let floatPtr = audioData.assumingMemoryBound(to: Float.self)
        let sampleCount = byteCount / MemoryLayout<Float>.size
        let frameCount = sampleCount / 2
        guard frameCount > 0 else { return }

        var sumL: Float = 0, sumR: Float = 0

        for i in 0..<frameCount {
            let l = floatPtr[i * 2]
            let r = floatPtr[i * 2 + 1]
            sumL += l * l
            sumR += r * r
        }

        levelL = sqrt(sumL / Float(frameCount))
        levelR = sqrt(sumR / Float(frameCount))

        // 피크 홀드 + 감쇠
        peakL = max(peakL * 0.95, levelL)
        peakR = max(peakR * 0.95, levelR)

        // PCM 스냅샷 (디스플레이용 다운샘플)
        let targetFrames = min(512, frameCount)
        let step = max(1, frameCount / targetFrames)
        var pcm = [Float](repeating: 0, count: targetFrames * 2)
        for i in 0..<targetFrames {
            let src = i * step
            pcm[i * 2] = floatPtr[src * 2]
            pcm[i * 2 + 1] = floatPtr[src * 2 + 1]
        }
        _displayPCM = pcm
    }

    private func updateCurrentPTS() {
        guard !ptsQueue.isEmpty else { return }

        var bestIdx = 0
        for i in 0..<ptsQueue.count {
            if ptsQueue[i].byteOffset <= totalBytesConsumed {
                bestIdx = i
            } else {
                break
            }
        }

        let entry = ptsQueue[bestIdx]
        let bytesAfter = totalBytesConsumed - entry.byteOffset
        currentPTS = entry.pts + Double(bytesAfter) / bytesPerSecond

        if bestIdx > 0 {
            ptsQueue.removeFirst(bestIdx)
        }
    }
}

private func audioQueueOutputCallback(
    inUserData: UnsafeMutableRawPointer?,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef
) {
    guard let userData = inUserData else { return }
    let output = Unmanaged<AudioOutput>.fromOpaque(userData).takeUnretainedValue()
    output.fillBuffer(inBuffer)
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nil)
}

final class RingBuffer {
    private var buffer: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private var readPos = 0
    private var writePos = 0
    private var count = 0

    var availableBytes: Int { return count }
    var freeBytes: Int { return capacity - count }

    init(capacity: Int) {
        self.capacity = capacity
        self.buffer = .allocate(capacity: capacity)
    }

    deinit { buffer.deallocate() }

    func write(_ data: Data) {
        let toWrite = min(data.count, capacity - count)
        guard toWrite > 0 else { return }
        data.withUnsafeBytes { rawBuf in
            guard let src = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let firstPart = min(toWrite, capacity - writePos)
            memcpy(buffer.advanced(by: writePos), src, firstPart)
            if firstPart < toWrite {
                memcpy(buffer, src.advanced(by: firstPart), toWrite - firstPart)
            }
            writePos = (writePos + toWrite) % capacity
            count += toWrite
        }
    }

    func read(into dst: UnsafeMutablePointer<UInt8>, count readCount: Int) {
        let toRead = min(readCount, count)
        let firstPart = min(toRead, capacity - readPos)
        memcpy(dst, buffer.advanced(by: readPos), firstPart)
        if firstPart < toRead {
            memcpy(dst.advanced(by: firstPart), buffer, toRead - firstPart)
        }
        readPos = (readPos + toRead) % capacity
        count -= toRead
    }

    func reset() {
        readPos = 0
        writePos = 0
        count = 0
    }
}
