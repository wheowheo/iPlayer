import Foundation
import QuartzCore

/// 프레임 드롭 원인 분류
enum DropReason: String {
    case lateFrame       = "Late Frame"       // 프레임 PTS가 마스터 클럭보다 3프레임 이상 늦음
    case queueStarvation = "Queue Starvation" // 렌더 시점에 큐가 비어있음 (디코딩 지연)
    case decodeSlow      = "Decode Slow"      // 디코딩 시간이 프레임 간격 초과
    case mainThreadBusy  = "Main Thread Busy" // 메인 스레드 디스패치 지연
}

/// 개별 드롭 이벤트
struct DropEvent {
    let time: Double           // 재생 시각 (초)
    let wallTime: Double       // 시스템 시각 (CACurrentMediaTime)
    let reason: DropReason
    let detail: String         // 상세 정보
    let framePTS: Double       // 드롭된 프레임의 PTS
    let masterClock: Double    // 드롭 시점의 마스터 클럭
    let queueDepth: Int        // 드롭 시점의 큐 깊이
}

/// 파이프라인 구간별 지연시간 스냅샷
struct PipelineLatency {
    var decodeTime: Double = 0       // 비디오 디코딩 소요 시간 (ms)
    var queueWaitTime: Double = 0    // 큐에서 대기한 시간 (ms)
    var dispatchLatency: Double = 0  // main.async 디스패치 지연 (ms)
    var renderInterval: Double = 0   // 렌더 콜백 간격 (ms)
}

/// 프레임 드롭 디버거
/// 파이프라인 전 구간을 계측하여 드롭 원인을 식별한다
final class FrameDropDebugger: @unchecked Sendable {

    // MARK: - 설정

    /// 활성화 여부
    var isEnabled = false {
        didSet {
            if isEnabled && !oldValue { reset() }
        }
    }

    /// 최대 보관 이벤트 수
    private let maxEvents = 500

    // MARK: - 드롭 이벤트 로그

    private(set) var dropEvents: [DropEvent] = []
    private let eventLock = NSLock()

    // MARK: - 파이프라인 계측 값

    // 디코딩 계측
    private var lastDecodeStart: Double = 0
    private var decodeTimeAccum: Double = 0
    private var decodeSampleCount: Int = 0
    private(set) var avgDecodeTime: Double = 0     // ms
    private(set) var maxDecodeTime: Double = 0     // ms
    private(set) var frameDuration: Double = 33.33  // ms (영상의 프레임 간격)

    // 큐 계측
    private(set) var minQueueDepth: Int = Int.max
    private(set) var maxQueueDepth: Int = 0
    private(set) var queueStarvationCount: Int = 0  // 큐가 비었던 횟수

    // 렌더 간격 계측
    private var lastRenderTime: Double = 0
    private var renderIntervalAccum: Double = 0
    private var renderSampleCount: Int = 0
    private(set) var avgRenderInterval: Double = 0  // ms
    private(set) var maxRenderInterval: Double = 0  // ms

    // 메인 스레드 디스패치 계측
    private var dispatchLatencyAccum: Double = 0
    private var dispatchSampleCount: Int = 0
    private(set) var avgDispatchLatency: Double = 0 // ms
    private(set) var maxDispatchLatency: Double = 0 // ms

    // 드롭 원인별 카운트
    private(set) var dropsByReason: [DropReason: Int] = [
        .lateFrame: 0,
        .queueStarvation: 0,
        .decodeSlow: 0,
        .mainThreadBusy: 0,
    ]

    // 배압(backpressure) 계측
    private(set) var backpressureCount: Int = 0     // 큐 만원으로 읽기 대기한 횟수

    // MARK: - API

    func reset() {
        eventLock.lock()
        dropEvents.removeAll()
        eventLock.unlock()

        decodeTimeAccum = 0
        decodeSampleCount = 0
        avgDecodeTime = 0
        maxDecodeTime = 0

        minQueueDepth = Int.max
        maxQueueDepth = 0
        queueStarvationCount = 0

        lastRenderTime = 0
        renderIntervalAccum = 0
        renderSampleCount = 0
        avgRenderInterval = 0
        maxRenderInterval = 0

        dispatchLatencyAccum = 0
        dispatchSampleCount = 0
        avgDispatchLatency = 0
        maxDispatchLatency = 0

        dropsByReason = [
            .lateFrame: 0,
            .queueStarvation: 0,
            .decodeSlow: 0,
            .mainThreadBusy: 0,
        ]
        backpressureCount = 0
    }

    /// 영상 프레임 간격 설정 (파일 오픈 시 호출)
    func setFrameDuration(_ duration: Double) {
        frameDuration = duration * 1000  // sec → ms
    }

    // MARK: - 디코딩 계측

    /// 디코딩 시작 전 호출
    func decodeBegin() {
        guard isEnabled else { return }
        lastDecodeStart = CACurrentMediaTime()
    }

    /// 디코딩 완료 후 호출. 디코딩이 프레임 간격보다 느리면 decodeSlow 기록
    func decodeEnd(playbackTime: Double, masterClock: Double, queueDepth: Int) {
        guard isEnabled, lastDecodeStart > 0 else { return }
        let elapsed = (CACurrentMediaTime() - lastDecodeStart) * 1000  // ms

        decodeSampleCount += 1
        decodeTimeAccum += elapsed
        avgDecodeTime = decodeTimeAccum / Double(decodeSampleCount)
        if elapsed > maxDecodeTime { maxDecodeTime = elapsed }

        // 디코딩 시간이 프레임 간격의 80% 초과 → 병목 감지
        if elapsed > frameDuration * 0.8 {
            recordDrop(
                reason: .decodeSlow,
                detail: String(format: "decode=%.1fms (limit=%.1fms)", elapsed, frameDuration),
                playbackTime: playbackTime,
                framePTS: playbackTime,
                masterClock: masterClock,
                queueDepth: queueDepth
            )
        }
    }

    // MARK: - 큐 계측

    /// 렌더 시점에 큐 상태 기록
    func recordQueueDepth(_ depth: Int, playbackTime: Double, masterClock: Double) {
        guard isEnabled else { return }
        if depth < minQueueDepth { minQueueDepth = depth }
        if depth > maxQueueDepth { maxQueueDepth = depth }

        if depth == 0 {
            queueStarvationCount += 1
            recordDrop(
                reason: .queueStarvation,
                detail: "큐 비어있음 - 디코딩이 렌더링을 따라가지 못함",
                playbackTime: playbackTime,
                framePTS: playbackTime,
                masterClock: masterClock,
                queueDepth: 0
            )
        }
    }

    /// 배압(backpressure) 발생 기록 — 큐가 가득 차서 읽기를 멈춤
    func recordBackpressure() {
        guard isEnabled else { return }
        backpressureCount += 1
    }

    // MARK: - 렌더 간격 계측

    /// 렌더 콜백(CVDisplayLink/Thread)에서 매번 호출
    func recordRenderTick() {
        guard isEnabled else { return }
        let now = CACurrentMediaTime()
        if lastRenderTime > 0 {
            let interval = (now - lastRenderTime) * 1000  // ms
            renderSampleCount += 1
            renderIntervalAccum += interval
            avgRenderInterval = renderIntervalAccum / Double(renderSampleCount)
            if interval > maxRenderInterval { maxRenderInterval = interval }
        }
        lastRenderTime = now
    }

    // MARK: - 메인 스레드 디스패치 계측

    /// 프레임을 main.async로 보내기 직전 호출, 반환값을 displayFrame에서 사용
    func dispatchBegin() -> Double {
        guard isEnabled else { return 0 }
        return CACurrentMediaTime()
    }

    /// 메인 스레드에서 실제 displayFrame 시작 시 호출
    func dispatchEnd(token: Double, playbackTime: Double, masterClock: Double, queueDepth: Int) {
        guard isEnabled, token > 0 else { return }
        let latency = (CACurrentMediaTime() - token) * 1000  // ms

        dispatchSampleCount += 1
        dispatchLatencyAccum += latency
        avgDispatchLatency = dispatchLatencyAccum / Double(dispatchSampleCount)
        if latency > maxDispatchLatency { maxDispatchLatency = latency }

        // 디스패치 지연이 프레임 간격 초과 → 병목
        if latency > frameDuration {
            recordDrop(
                reason: .mainThreadBusy,
                detail: String(format: "dispatch=%.1fms (limit=%.1fms)", latency, frameDuration),
                playbackTime: playbackTime,
                framePTS: playbackTime,
                masterClock: masterClock,
                queueDepth: queueDepth
            )
        }
    }

    // MARK: - Late Frame 드롭 기록

    /// selectFrame()에서 늦은 프레임을 드롭할 때 호출
    func recordLateDrop(framePTS: Double, masterClock: Double, diff: Double, queueDepth: Int) {
        guard isEnabled else { return }
        recordDrop(
            reason: .lateFrame,
            detail: String(format: "diff=%+.1fms (PTS=%.3f, clock=%.3f)", diff * 1000, framePTS, masterClock),
            playbackTime: masterClock,
            framePTS: framePTS,
            masterClock: masterClock,
            queueDepth: queueDepth
        )
    }

    // MARK: - 리포트 생성

    /// 정보 오버레이용 요약 문자열
    var summary: String {
        guard isEnabled else { return "" }

        let totalDrops = dropsByReason.values.reduce(0, +)
        var lines: [String] = []

        lines.append("─── Drop Debugger ───")
        lines.append(String(format: "Decode: avg %.1fms / max %.1fms (limit %.1fms)",
                            avgDecodeTime, maxDecodeTime, frameDuration))
        lines.append(String(format: "Render interval: avg %.1fms / max %.1fms",
                            avgRenderInterval, maxRenderInterval))
        lines.append(String(format: "Dispatch: avg %.1fms / max %.1fms",
                            avgDispatchLatency, maxDispatchLatency))
        lines.append(String(format: "Queue: %d~%d (starvation: %d, backpressure: %d)",
                            minQueueDepth == Int.max ? 0 : minQueueDepth,
                            maxQueueDepth, queueStarvationCount, backpressureCount))

        if totalDrops > 0 {
            lines.append(String(format: "Drops: %d total", totalDrops))
            for (reason, count) in dropsByReason.sorted(by: { $0.value > $1.value }) where count > 0 {
                lines.append(String(format: "  %@: %d", reason.rawValue, count))
            }

            // 주요 병목 진단
            lines.append("Bottleneck: \(diagnoseBottleneck())")
        } else {
            lines.append("Drops: 0 (정상)")
        }

        return lines.joined(separator: "\n")
    }

    /// 최근 드롭 이벤트 (최대 count개)
    func recentEvents(count: Int = 20) -> [DropEvent] {
        eventLock.lock()
        let events = Array(dropEvents.suffix(count))
        eventLock.unlock()
        return events
    }

    /// 병목 원인 자동 진단
    func diagnoseBottleneck() -> String {
        let total = dropsByReason.values.reduce(0, +)
        guard total > 0 else { return "없음" }

        // 가장 많은 원인 찾기
        let top = dropsByReason.max(by: { $0.value < $1.value })!

        switch top.key {
        case .lateFrame:
            if maxDecodeTime > frameDuration * 0.8 {
                return "디코딩 지연 → HW 가속 확인 필요"
            }
            if maxDispatchLatency > frameDuration {
                return "메인 스레드 지연 → UI 작업 최적화 필요"
            }
            return "프레임 타이밍 초과 → 클럭 드리프트 가능성"

        case .queueStarvation:
            if maxDecodeTime > frameDuration * 0.5 {
                return "디코딩 병목 → 큐가 고갈됨"
            }
            return "I/O 병목 → 디스크 읽기 또는 demuxer 지연"

        case .decodeSlow:
            return "디코딩 병목 (avg \(String(format: "%.0f", avgDecodeTime))ms) → HW 가속 또는 해상도 확인"

        case .mainThreadBusy:
            return "메인 스레드 병목 (max \(String(format: "%.0f", maxDispatchLatency))ms) → UI 업데이트 과부하"
        }
    }

    // MARK: - 내부

    private func recordDrop(reason: DropReason, detail: String, playbackTime: Double,
                            framePTS: Double, masterClock: Double, queueDepth: Int) {
        dropsByReason[reason, default: 0] += 1

        let event = DropEvent(
            time: playbackTime,
            wallTime: CACurrentMediaTime(),
            reason: reason,
            detail: detail,
            framePTS: framePTS,
            masterClock: masterClock,
            queueDepth: queueDepth
        )

        eventLock.lock()
        dropEvents.append(event)
        if dropEvents.count > maxEvents {
            dropEvents.removeFirst(dropEvents.count - maxEvents)
        }
        eventLock.unlock()
    }
}
