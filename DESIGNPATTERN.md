# iPlayer 설계 패턴 및 스레딩 아키텍처

## 목차
1. [사용된 디자인 패턴](#1-사용된-디자인-패턴)
2. [엔트리포인트 및 초기화 흐름](#2-엔트리포인트-및-초기화-흐름)
3. [스레딩 아키텍처](#3-스레딩-아키텍처)
4. [스레드 간 통신](#4-스레드-간-통신)
5. [동기화 메커니즘 (Locking)](#5-동기화-메커니즘-locking)
6. [데이터 파이프라인](#6-데이터-파이프라인)
7. [클럭 동기화](#7-클럭-동기화)
8. [상태 머신](#8-상태-머신)

---

## 1. 사용된 디자인 패턴

### 1.1 싱글톤 (Singleton)
| 클래스 | 접근 | 용도 |
|--------|------|------|
| `AppDatabase.shared` | `nonisolated(unsafe) static` | 통합 SQLite DB |
| `ClothingDatabase.shared` | `nonisolated(unsafe) static` | 의류 CRUD (AppDatabase 위임) |

### 1.2 옵저버 (Observer) — 클로저 콜백 방식
`PlayerController`가 발행하고 `PlayerView`가 구독하는 이벤트:

```
PlayerController                    PlayerView
─────────────                      ──────────
onFrameReady ──────────────────→ displayFrame()
onTimeUpdate ──────────────────→ updateTimeDisplay()
onSubtitleUpdate ──────────────→ updateSubtitle()
onStateChange ─────────────────→ updatePlayButton()
onMediaInfo ───────────────────→ applyVideoRotation()
onBuffering ───────────────────→ bufferingView.isHidden
onInputSourceChange ───────────→ 카메라/파일 UI 전환
onRenderModeChange ────────────→ (미사용)
```

추가 콜백 체인:
```
ObjectDetector.onDetectionUpdate ──→ PlayerView (오버레이 갱신)
ObjectDetector.onClothingChanged ──→ PlayerView (옷 이름 표시)
CameraController.onFrameReady ────→ PlayerController (프레임 전달)
SeekBar.onSeek ───────────────────→ PlayerController.seek()
```

### 1.3 생산자-소비자 (Producer-Consumer)
3단계 파이프라인으로 구성:

```
[생산자]          [버퍼]              [소비자]
Demux Thread ──→ videoPacketQueue ──→ Decode Thread
Demux Thread ──→ AudioOutput Ring ──→ AudioQueue Callback
Decode Thread ─→ frameRing ────────→ Render/DisplayLink
```

### 1.4 전략 (Strategy)
- **렌더링 전략**: `RenderMode.displayLink` ↔ `.thread`
  - `startRenderer()` → `startDisplayLink()` 또는 `startRenderThread()`
- **AI 탐지 전략**: `DetectorMode` enum (9종)
  - `runMode()` → 모드별 Vision/CoreML 요청 분기

### 1.5 상태 머신 (State Machine)
```
PlaybackState: idle → playing ⇄ paused → stopped
InputSource:   file ⇄ camera
DetectionState: idle → detecting ⇄ deferred
RenderMode:    displayLink ⇄ thread
```

### 1.6 링 버퍼 (Ring Buffer)
| 버퍼 | 용량 | 데이터 | 쓰기 | 읽기 |
|------|------|--------|------|------|
| `FrameRingBuffer` | 256 프레임 | VideoFrame | Decode Thread | Render/DisplayLink |
| `RingBuffer` (오디오) | 8MB | PCM Float32 | Demux Thread | AudioQueue Callback |

### 1.7 어댑터 (Adapter)
- `VideoFrame` — CVPixelBuffer(HW) / CGImage(SW) 추상화
- `DetectionResult` — 9종 AI 결과를 단일 enum으로 통합
- `DetectionOverlayLayer` — 결과 타입별 렌더링 분기

### 1.8 파사드 (Facade)
- `PlayerController` — FFmpeg 디먹서/디코더/오디오/스레드를 단일 인터페이스로 래핑
- `ObjectDetector` — CoreML/Vision/SceneKit을 단일 `processFrame()` 호출로 래핑

### 1.9 팩토리 (Factory)
- `ObjectDetector.loadModel(for:)` — DetectorMode에 따라 CoreML 모델 또는 Vision 요청 생성
- `FaceRenderer3D.loadFromImage()` — 이미지에서 3D 텍스처 메시 생성

---

## 2. 엔트리포인트 및 초기화 흐름

```
@main iPlayerApp.main()
  │
  ├─ NSApplication.shared 생성
  ├─ AppDelegate 생성
  └─ app.run()
      │
      ├─ applicationDidFinishLaunching()
      │   │
      │   ├─ setupMenu()              ← 메뉴바 구성
      │   ├─ NSWindow 생성             ← 960x540, 자동 저장
      │   ├─ PlayerController 생성     ← 핵심 엔진
      │   │   ├─ Demuxer 생성
      │   │   ├─ VideoDecoder 생성
      │   │   ├─ AudioDecoder 생성
      │   │   ├─ AudioOutput 생성
      │   │   └─ CameraController 생성
      │   │
      │   ├─ onMediaInfo 콜백 등록     ← 창 크기 조절
      │   ├─ PlayerView 생성           ← UI 레이어
      │   │   ├─ setupView()           ← CALayer, 컨트롤, 오버레이
      │   │   ├─ setupCallbacks()      ← Observer 패턴 연결
      │   │   └─ ObjectDetector 생성   ← AI 엔진
      │   │
      │   ├─ window.contentView = playerView
      │   └─ CLI 인수 처리 (파일 경로, --bench)
      │
      └─ Run Loop 시작
```

---

## 3. 스레딩 아키텍처

### 3.1 스레드 맵

```
┌─────────────────────────────────────────────────────┐
│                    Main Thread                       │
│  AppDelegate, PlayerView, UI 업데이트, 이벤트 처리     │
│  NSMenu, NSWindow, CALayer 렌더링                    │
└─────────┬───────────┬───────────┬───────────────────┘
          │           │           │
          ▼           ▼           ▼
┌─────────────┐ ┌───────────┐ ┌──────────────────┐
│ Demux Thread │ │  Decode   │ │ Render Thread    │
│ iPlayer.Demux│ │  Thread   │ │ iPlayer.Render   │
│ QoS:userInt  │ │iPlayer.   │ │ QoS:userInt      │
│              │ │VideoDecode│ │ (Thread 모드)     │
│ • readPacket │ │QoS:userInt│ │ OR               │
│ • 오디오 디코딩│ │           │ │ CVDisplayLink    │
│ • seek 처리  │ │• decode() │ │ (DisplayLink 모드)│
│ • 배압 관리  │ │• drain()  │ │                  │
└──────┬───────┘ └─────┬─────┘ └────────┬─────────┘
       │               │                │
       ▼               ▼                ▼
┌──────────────────────────────────────────────┐
│              AudioQueue Thread               │
│  (AudioToolbox 내부 스레드)                    │
│  • fillBuffer() 콜백 (~21ms 간격)            │
└──────────────────────────────────────────────┘

┌─────────────────┐  ┌────────────────────────┐
│ Camera Capture   │  │ Object Detection       │
│ iPlayer.Camera   │  │ iPlayer.ObjectDetection│
│ DispatchQueue    │  │ DispatchQueue          │
│ QoS:userInteract │  │ QoS:utility            │
│ • AVCapture 콜백 │  │ • CoreML/Vision 추론   │
└─────────────────┘  └────────────────────────┘
```

### 3.2 스레드별 책임

| 스레드 | QoS | 생명주기 | 핵심 역할 |
|--------|-----|---------|----------|
| **Main** | — | 앱 전체 | UI 업데이트, 이벤트 처리, 콜백 수신 |
| **Demux** | userInteractive | play()~stop() | 패킷 읽기, 오디오 디코딩, seek |
| **Decode** | userInteractive | play()~stop() | 비디오 디코딩 (VideoToolbox HW) |
| **Render** | userInteractive | play()~stop() | 프레임 선택, 클럭 계산 (Thread 모드) |
| **DisplayLink** | 시스템 | play()~stop() | VSync 동기 렌더링 (DisplayLink 모드) |
| **AudioQueue** | 시스템 | start()~stop() | PCM 데이터 소비, PTS 추적 |
| **Camera** | userInteractive | start()~stop() | 카메라 프레임 캡처 |
| **Detection** | utility | 상시 | AI 추론 (비디오보다 낮은 우선순위) |

---

## 4. 스레드 간 통신

### 4.1 통신 방식

```
┌──────────┐  seekLock    ┌──────────┐  packetQueue  ┌──────────┐
│   Main   │────────────→│  Demux   │──────────────→│  Decode  │
│  Thread  │  seekRequest │  Thread  │  Semaphore    │  Thread  │
└──────────┘             └──────────┘               └──────────┘
     ↑                        │                          │
     │                        │ audioOutput.enqueue()    │
     │                        ▼                          │
     │                  ┌──────────┐                     │
     │                  │AudioQueue│                     │
     │                  │ Callback │                     │
     │                  └──────────┘                     │
     │                                                   │
     │  DispatchQueue.main.async { onFrameReady?() }    │
     │◀──────────────────────────────────────────────────│
     │                                                   │
     │                  ┌──────────┐                     │
     │  onBuffering?()  │  Render  │  queueLock          │
     │◀─────────────────│  Thread  │◀────────────────────│
     │                  └──────────┘   frameRing
```

### 4.2 콜백 디스패치 규칙

**워커 → 메인 스레드** (모든 UI 업데이트):
```swift
DispatchQueue.main.async { [weak self] in
    self?.onFrameReady?(frame)
    self?.onTimeUpdate?(time, duration)
    self?.onBuffering?(isBuffering)
}
```

**메인 → 워커 스레드** (제어 신호):
```swift
// seek 요청
seekLock.lock()
seekRequest = target  // Demux Thread가 폴링
seekLock.unlock()

// 정지 신호
isDemuxing = false    // Boolean 플래그 (직접 접근)
```

---

## 5. 동기화 메커니즘 (Locking)

### 5.1 NSLock 목록

| Lock 이름 | 보호 대상 | 접근 스레드 | 임계 구간 |
|----------|----------|-----------|----------|
| `packetQueueLock` | `videoPacketQueue: [AVPacket]` | Demux ↔ Decode | enqueue/dequeue/flush |
| `queueLock` | `frameRing: FrameRingBuffer` | Decode ↔ Render ↔ Main | append/removeFirst/removeAll/count/isEmpty |
| `videoDecoderLock` | `VideoDecoder` 인스턴스 | Decode ↔ Demux(seek) | decode() ↔ flush() 경합 방지 |
| `seekLock` | `seekRequest: Double?` | Main ↔ Demux ↔ Decode | seek 요청 읽기/쓰기 |
| `AudioOutput.lock` | ringBuffer, ptsQueue, levels | Demux ↔ AudioQueue | enqueue ↔ fillBuffer |
| `resultsLock` | `_latestResult: DetectionResult` | Detection ↔ Main | 결과 읽기/쓰기 |

### 5.2 DispatchSemaphore 목록

| 세마포어 | 초기값 | 용도 | signal() | wait() |
|---------|-------|------|----------|--------|
| `packetQueueSemaphore` | 0 | 패킷 도착 신호 | Demux (패킷당 1회) | Decode (0.1초 타임아웃) |
| `prebufferReady` | 0 | 프리버퍼링 완료 | Decode (목표 달성 시) | play() (1.0초 타임아웃) |
| `demuxThreadDone` | 0 | Demux 스레드 종료 대기 | Demux (종료 시) | stopDemuxThread() |
| `decodeThreadDone` | 0 | Decode 스레드 종료 대기 | Decode (종료 시) | stopDecodeThread() |
| `renderThreadDone` | 0 | Render 스레드 종료 대기 | Render (종료 시) | stopRenderThread() |

### 5.3 Lock 획득 순서 (교착 방지)

교착 상태를 방지하기 위해 다음 순서를 준수:
```
seekLock → packetQueueLock → videoDecoderLock → queueLock
```

어떤 스레드도 역순으로 lock을 획득하지 않는다.

### 5.4 Lock-Free 영역

| 변수 | 접근 방식 | 안전성 |
|------|----------|--------|
| `isDemuxing`, `isDecoding`, `isRendering` | 직접 읽기/쓰기 | Boolean 원자성 (ARM64) |
| `isBusy` (ObjectDetector) | 직접 읽기/쓰기 | 단일 쓰기 스레드 |
| `playbackSpeed` | 직접 읽기/쓰기 | Float 원자성 (ARM64) |
| `currentTime`, `currentFPS` | 직접 읽기/쓰기 | Double, 읽기 지연 허용 |

---

## 6. 데이터 파이프라인

### 6.1 비디오 재생 파이프라인

```
 ┌─────────┐    ┌──────────┐    ┌──────────┐    ┌─────────┐    ┌──────────┐
 │  파일   │───→│  Demuxer │───→│  Packet  │───→│ Video   │───→│  Frame   │
 │ (mp4,  │    │ (FFmpeg) │    │  Queue   │    │ Decoder │    │  Ring    │
 │  mkv)  │    │          │    │ (120 max)│    │(VT/SW)  │    │(256 max) │
 └─────────┘    └──────────┘    └──────────┘    └─────────┘    └──────────┘
                                                                     │
                     ┌──────────────────────────────────────────────┘
                     ▼
              ┌──────────────┐    ┌──────────┐    ┌──────────┐
              │ selectFrame  │───→│ Display  │───→│ CALayer  │
              │ (PTS 기반)   │    │  Frame   │    │ 렌더링   │
              │ 클럭 동기화   │    │(main thr)│    │          │
              └──────────────┘    └──────────┘    └──────────┘
```

### 6.2 오디오 파이프라인

```
 ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
 │  Demux   │───→│  Audio   │───→│   Ring   │───→│ Audio    │
 │  Thread  │    │ Decoder  │    │  Buffer  │    │  Queue   │
 │          │    │(swresamp)│    │  (8MB)   │    │(3 bufs)  │
 └──────────┘    └──────────┘    └──────────┘    └──────────┘
                  48kHz/2ch/F32      ↓                ↓
                                  PTS 추적       TimePitch
                                  레벨 미터       배속 재생
```

### 6.3 AI 탐지 파이프라인

```
 ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐
 │ Display  │───→│ Object   │───→│ Vision/  │───→│ Detection│
 │  Frame   │    │ Detector │    │  CoreML  │    │ Overlay  │
 │(main thr)│    │(util Q)  │    │  (ANE/   │    │  Layer   │
 │          │    │          │    │   GPU)   │    │(main thr)│
 └──────────┘    └──────────┘    └──────────┘    └──────────┘
      │            isBusy 가드       비동기          결과 캐시
      │            프레임 스킵        추론          latestResult
      └──── queueDepth 기반 적응적 스케줄링 ────────────┘
```

---

## 7. 클럭 동기화

### 7.1 마스터 클럭 선택

```
computeMasterClock() 호출 (매 렌더 틱)
  │
  ├─ 오디오 있음 && compensatedPTS > 0?
  │   ├─ YES: 오디오 클럭 사용
  │   │        clock = audioOutput.compensatedPTS
  │   │        (레이턴시 보상: ~85ms)
  │   │
  │   │   오디오 스톨 감지?
  │   │   ├─ PTS 변화 < 0.001 && 0.5초 이상?
  │   │   │   └─ 벽시계 전환
  │   │   └─ 정상: 오디오 클럭 유지
  │   │
  │   └─ NO: 벽시계 사용
  │            clock = playbackStartPTS + elapsed * speed
  │
  └─ return min(clock, duration)
```

### 7.2 프레임 선택

```
일반 속도 (≤2x):
  frame.pts - masterClock < dropThreshold(-3프레임)? → 드롭
  frame.pts - masterClock < -frameDuration?          → 표시 (약간 늦음)
  frame.pts - masterClock ≤ showThreshold(0.5프레임)? → 표시 (적시)
  그 외?                                             → 대기

고속 (>2x):
  frame.pts ≤ masterClock + showThreshold?
    → frameToShow = frame (최신 후보로 갱신)
    → 충분히 가까우면 break
  frame.pts > showThreshold?
    → 대기 (미래 프레임)
```

---

## 8. 상태 머신

### 8.1 재생 상태 전이

```
        ┌───────────────────────────────────────────┐
        │                                           │
        ▼                                           │
    ┌──────┐  openFile()  ┌─────────┐  pause()  ┌──────┐
    │ idle │─────────────→│ playing │──────────→│paused│
    └──────┘              └─────────┘           └──────┘
        ▲                      │                    │
        │                      │    play()          │
        │                      │◀───────────────────┘
        │                      │
        │    stop()            │  stop()
        │◀─────────────────────│
        │                      │
    ┌───────┐                  │  EOF
    │stopped│◀─────────────────┘  (auto-pause)
    └───────┘
```

### 8.2 Seek 흐름

```
Main Thread          Demux Thread          Decode Thread
───────────          ────────────          ─────────────
seek(target)
  │
  ├─ seekLock.lock()
  ├─ seekRequest = target
  └─ seekLock.unlock()
                     │
                     ├─ seekLock.lock()
                     ├─ read seekRequest
                     ├─ seekLock.unlock()
                     │
                     ├─ performSeek():
                     │  ├─ seekTargetPTS = target
                     │  ├─ flushPacketQueue()
                     │  ├─ demuxer.seek()
                     │  ├─ videoDecoderLock.lock()
                     │  ├─ videoDecoder.flush()
                     │  ├─ videoDecoderLock.unlock()
                     │  ├─ audioDecoder.flush()
                     │  ├─ audioOutput.reset()
                     │  ├─ queueLock → frameRing.removeAll()
                     │  ├─ resetClock(fromPTS: target)
                     │  └─ main.async { onTimeUpdate() }
                     │
                     ├─ 새 패킷 읽기 재개
                     │  (오디오: seekTargetPTS 이전 버림)
                     │
                     └─ packetQueueSemaphore.signal()
                                              │
                                              ├─ seekLock → seeking? skip
                                              ├─ dequeue packet
                                              ├─ videoDecoderLock.lock()
                                              ├─ decode(packet)
                                              ├─ videoDecoderLock.unlock()
                                              └─ queueLock → frameRing.append()
```

### 8.3 버퍼링 상태 전이

```
Render/DisplayLink Thread:
  │
  ├─ frameRing.isEmpty && !demuxEOF?
  │   ├─ YES:
  │   │   isBuffering = true
  │   │   audioOutput.pause()
  │   │   main.async { onBuffering?(true) }  → 스피너 표시
  │   │   return (렌더링 건너뜀)
  │   │
  │   └─ isBuffering && frameRing.count ≥ 5?
  │       isBuffering = false
  │       audioOutput.resume()
  │       resetClock(fromPTS: currentTime)
  │       main.async { onBuffering?(false) } → 스피너 숨김
  │
  └─ 정상 프레임 선택 + 렌더링
```

---

*이 문서는 iPlayer 코드베이스의 실제 구현을 기반으로 작성되었습니다.*
*2026-03-30 기준, 커밋 fd023a4*
