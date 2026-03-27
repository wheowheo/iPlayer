# iPlayer 개발 로그

개발 과정에서의 시행착오와 해결 과정을 기록한다.

---

## Phase 1

### 2026-03-27: 프로젝트 시작
- 환경: macOS, Swift 6.2.1, Xcode 26.1.1, FFmpeg 8.1 (Homebrew)
- FFmpeg은 /opt/homebrew/opt/ffmpeg 경로에 설치됨
- VideoToolbox, AudioToolbox 활성화 확인

### 2026-03-27: Phase 1 빌드 성공
- FFmpeg 8.1의 Swift 바인딩에서 타입 변경 사항 다수 발견:
  - `SwsContext`가 `OpaquePointer`가 아니라 `UnsafeMutablePointer<SwsContext>`로 변경됨
  - `SWS_BILINEAR`이 `SwsFlags` 타입으로 변경됨 → `.rawValue`로 Int32 변환 필요
  - `AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX`는 이미 Int 타입, `.rawValue` 불필요
  - `av_frame_free`는 `UnsafeMutablePointer<AVFrame>?`를 인아웃으로 받음
  - Swift 6의 Sendable 클로저 제약으로 Timer 콜백에서 MainActor 격리 필요
- 링커 경고(macOS 14.0 vs 26.0)는 Homebrew FFmpeg이 최신 SDK로 빌드되어 발생, 무해함
