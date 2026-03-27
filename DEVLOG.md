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

### 2026-03-27: Phase 2 비디오 디코딩 파이프라인 동작 확인
- H.264 테스트 비디오에서 VideoToolbox HW 가속 디코딩 성공
- AAC 오디오 디코더 + swresample 변환 정상 동작
- GUI 앱에서 print()는 터미널에 출력 안됨 → fputs(stderr)로 로그 함수 분리
- application(_:openFile:)이 applicationDidFinishLaunching 전에 호출될 수 있어 nil 체크 필요
- CVPixelBuffer를 HW 디코딩에서 추출 시 retain 필요 (프레임 재사용으로 인한 dangling 방지)

### 2026-03-27: Phase 3~7 통합 구현
- 오디오 출력 (AudioQueue), A/V PTS 싱크, 볼륨 조절 모두 통합
- 재생 제어 UI (컨트롤 바, 시크바, 재생/일시정지 버튼, 시간 표시)
- 단축키 바인딩 완료 (Space, F, 방향키, Tab, M, [, ], Cmd+F 등)
- Tab 정보 오버레이 (FPS, 코덱, 해상도, 디코딩 모드)
- SRT/SMI 자막 파서 + PTS 기반 렌더링 + 싱크 조절 (-/= 키)
- 드래그 앤 드롭 파일 열기 (비디오/자막 파일 자동 감지)
- 전체화면 (Cmd+F, 더블클릭)
- 창 비율 유지 (영상 가로세로비에 맞춤)
- 자막 인코딩 자동 감지 (UTF-8, UTF-16, EUC-KR)
- 자막 파일 자동 탐색 (비디오와 같은 이름)
- 메뉴바에 파일/재생/윈도우 메뉴 추가
- 비디오 전용(오디오 없는) 파일 재생 시 비디오 PTS 기반 클럭 폴백
