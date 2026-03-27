import Foundation
import AudioToolbox

final class AudioOutput {
    private var audioQueue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef?] = []
    private let bufferCount = 3
    private let bufferSize = 4096 * 4  // ~21ms at 48kHz stereo float32

    private var ringBuffer = RingBuffer(capacity: 2 * 1024 * 1024) // 2MB
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

    private(set) var currentPTS: Double = 0
    private var ptsQueue: [(byteOffset: Int, pts: Double)] = []
    private var totalBytesConsumed: Int = 0
    private var totalBytesWritten: Int = 0
    private let bytesPerSecond: Double = 48000 * 2 * 4

    var playbackRate: Float = 1.0 {
        didSet {
            if let queue = audioQueue {
                AudioQueueSetParameter(queue, kAudioQueueParam_PlayRate, Float32(playbackRate))
            }
        }
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

        // 배속 재생 지원
        var enableTimePitch: UInt32 = 1
        AudioQueueSetProperty(queue, kAudioQueueProperty_EnableTimePitch,
                              &enableTimePitch, UInt32(MemoryLayout<UInt32>.size))
        AudioQueueSetParameter(queue, kAudioQueueParam_PlayRate, Float32(playbackRate))
        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, Float32(volume))

        // 버퍼 할당 및 초기 enqueue (무음)
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

        log("[AudioOutput] 시작됨")
        return true
    }

    func enqueue(buffer: AudioBuffer) {
        lock.lock()
        // PTS 매핑 기록
        ptsQueue.append((byteOffset: totalBytesWritten, pts: buffer.pts))
        // 오래된 PTS 매핑 정리
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
        lock.unlock()
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

            // PTS 보간: 현재 소비 바이트에 해당하는 PTS 계산
            updateCurrentPTS()
        } else {
            // 데이터 없으면 무음
            memset(buffer.pointee.mAudioData, 0, bufferSize)
            buffer.pointee.mAudioDataByteSize = UInt32(bufferSize)
        }
        lock.unlock()
    }

    private func updateCurrentPTS() {
        // ptsQueue에서 현재 소비 위치에 가장 가까운 PTS 찾기
        guard !ptsQueue.isEmpty else { return }

        // 이미 지나간 PTS 항목들 중 마지막 것 찾기
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

        // 사용 완료된 이전 항목 정리
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

// 링 버퍼
final class RingBuffer {
    private var buffer: UnsafeMutablePointer<UInt8>
    private let capacity: Int
    private var readPos = 0
    private var writePos = 0
    private var count = 0

    var availableBytes: Int { return count }

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
