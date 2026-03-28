/// O(1) enqueue/dequeue 원형 버퍼 (비디오 프레임 큐용)
struct FrameRingBuffer {
    private var storage: [VideoFrame?]
    private var head = 0   // 읽기 위치
    private var tail = 0   // 쓰기 위치
    private(set) var count = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    var isEmpty: Bool { count == 0 }

    var first: VideoFrame? {
        guard count > 0 else { return nil }
        return storage[head]
    }

    @discardableResult
    mutating func removeFirst() -> VideoFrame? {
        guard count > 0 else { return nil }
        let frame = storage[head]
        storage[head] = nil
        head = (head + 1) % capacity
        count -= 1
        return frame
    }

    var isFull: Bool { count >= capacity }

    @discardableResult
    mutating func append(_ frame: VideoFrame) -> Bool {
        guard count < capacity else { return false }
        storage[tail] = frame
        tail = (tail + 1) % capacity
        count += 1
        return true
    }

    mutating func append(contentsOf frames: [VideoFrame]) {
        for frame in frames {
            append(frame)
        }
    }

    mutating func removeAll() {
        head = 0
        tail = 0
        count = 0
        // nil로 참조 해제 (메모리)
        for i in 0..<capacity {
            storage[i] = nil
        }
    }
}
