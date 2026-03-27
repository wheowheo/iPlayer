import Foundation
import AudioToolbox

final class AudioOutput {
    private var audioQueue: AudioQueueRef?
    private var buffers: [AudioQueueBufferRef?] = []
    private let bufferCount = 3
    private let bufferSize = 8192 * 4 // enough for ~42ms at 48kHz stereo float32

    private var ringBuffer = RingBuffer(capacity: 1024 * 1024) // 1MB ring buffer
    private let lock = NSLock()

    var volume: Float = 1.0 {
        didSet {
            if let queue = audioQueue {
                AudioQueueSetParameter(queue, kAudioQueueParam_Volume, Float32(volume))
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

    // 현재 오디오 재생 시간 (A/V 싱크용)
    private(set) var currentPTS: Double = 0
    private var basePTS: Double = 0
    private var bytesWrittenSinceBase: Int = 0
    private let bytesPerSecond: Double = 48000 * 2 * 4 // 48kHz * 2ch * float32

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
            mBytesPerPacket: 8,     // 2ch * 4bytes
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let callbackPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioQueueNewOutput(
            &format,
            audioQueueCallback,
            callbackPointer,
            nil, nil, 0,
            &audioQueue
        )

        guard status == noErr, let queue = audioQueue else {
            print("[AudioOutput] AudioQueue 생성 실패: \(status)")
            return false
        }

        // 타임 피치 활성화 (배속 재생용)
        AudioQueueSetParameter(queue, kAudioQueueParam_PlayRate, Float32(playbackRate))
        var enableTimePitch: UInt32 = 1
        AudioQueueSetProperty(queue, kAudioQueueProperty_EnableTimePitch,
                              &enableTimePitch, UInt32(MemoryLayout<UInt32>.size))

        for _ in 0..<bufferCount {
            var buffer: AudioQueueBufferRef?
            AudioQueueAllocateBuffer(queue, UInt32(bufferSize), &buffer)
            if let buffer = buffer {
                buffer.pointee.mAudioDataByteSize = 0
                buffers.append(buffer)
                fillBuffer(buffer)
                AudioQueueEnqueueBuffer(queue, buffer, 0, nil)
            }
        }

        AudioQueueSetParameter(queue, kAudioQueueParam_Volume, Float32(volume))
        AudioQueueStart(queue, nil)
        return true
    }

    func enqueue(buffer: AudioBuffer) {
        lock.lock()
        if basePTS == 0 || abs(buffer.pts - currentPTS) > 1.0 {
            basePTS = buffer.pts
            bytesWrittenSinceBase = 0
        }
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
        basePTS = 0
        bytesWrittenSinceBase = 0
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
        basePTS = 0
        bytesWrittenSinceBase = 0
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

            bytesWrittenSinceBase += toRead
            currentPTS = basePTS + Double(bytesWrittenSinceBase) / bytesPerSecond
        } else {
            // 무음 채우기
            memset(buffer.pointee.mAudioData, 0, bufferSize)
            buffer.pointee.mAudioDataByteSize = UInt32(bufferSize)
        }
        lock.unlock()
    }
}

private func audioQueueCallback(
    inUserData: UnsafeMutableRawPointer?,
    inAQ: AudioQueueRef,
    inBuffer: AudioQueueBufferRef
) {
    guard let userData = inUserData else { return }
    let output = Unmanaged<AudioOutput>.fromOpaque(userData).takeUnretainedValue()
    output.fillBuffer(inBuffer)
    AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, nil)
}

// 간단한 링 버퍼
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

    deinit {
        buffer.deallocate()
    }

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
