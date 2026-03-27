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

---

## 버그 수정

### 2026-03-27: 재생 시간이 전체 시간을 초과하는 문제
- **증상**: 오디오 PTS 클럭이 영상 길이보다 큰 값을 반환하여 시간 표시가 전체 길이를 넘어감
- **원인**: `currentTime` 갱신 시 duration 상한 체크가 없었음
- **수정**: 모든 `currentTime` 갱신 지점에 `min(값, duration)` 클램핑 추가.
  duration 도달 시 자동 일시정지 처리

### 2026-03-27: 파일 없이 재생 버튼 누르면 segfault
- **증상**: 영상을 열지 않은 상태에서 Space 키(재생)를 누르면 즉시 크래시
- **원인**: `play()` 호출 시 `demuxer.formatCtx`가 nil인 상태에서 readThread가 시작되어
  `readPacket()` → `av_read_frame(nil, ...)` 호출로 segfault 발생
- **수정**: `play()`, `seek()`, `stepFrame()`에 `guard demuxer.formatCtx != nil` 가드 추가

### 2026-03-27: 드래그 앤 드롭이 동작하지 않는 문제
- **증상**: Finder에서 비디오 파일을 창에 드래그해도 반응 없음
- **원인**: `registerForDraggedTypes`에 `.fileURL`만 등록했으나, Finder 드래그에서
  `readObjects(forClasses:)` 호출 시 URL을 못 읽는 경우가 있음
- **수정**: 등록 타입에 `.URL`, `.string` 추가. `performDragOperation`에서 3단계 폴백
  (readObjects → propertyList → string 경로) 적용. `draggingUpdated`, `prepareForDragOperation`
  오버라이드 추가

### 2026-03-27: 세로 영상(스마트폰 촬영)이 가로로 눕혀서 재생되는 문제
- **증상**: 카카오톡으로 전송된 스마트폰 세로 촬영 영상(Sample/KakaoTalk_20210510_205904185.mp4)이
  가로가 짧고 세로가 긴 영상임에도 가로로 눕혀진 형태로 재생됨
- **원인**: MP4 컨테이너의 Display Matrix side data에 `rotation: -90`이 명시되어 있으나
  (ffprobe로 확인: `"rotation": -90`), 플레이어가 이 메타데이터를 완전히 무시하고 있었음.
  실제 코덱 해상도는 854x480이지만 -90도 회전이 적용되어야 480x854(세로)로 표시되어야 함
- **분석 과정**:
  1. `ffprobe -show_streams`로 영상 분석 → side_data_list에서 Display Matrix 확인
  2. rotation 값 -90도 = 실제 표시 시 90도 시계방향 회전 필요
  3. FFmpeg API에서 `av_display_rotation_get()` 함수로 Display Matrix에서 각도 추출 가능
  4. 이 함수는 inline이 아니라 `libavutil/display.h`에 선언된 일반 함수
- **수정 내용** (총 6개 파일 수정):
  1. **CFFmpeg/shim.h**: `<libavutil/display.h>` 헤더 추가.
     `iplayer_get_stream_rotation()` 헬퍼 함수 작성 — `av_packet_side_data_get()`으로
     스트림의 coded_side_data에서 `AV_PKT_DATA_DISPLAYMATRIX`를 찾고,
     `av_display_rotation_get()`으로 각도 추출 후 0~360도로 정규화.
     (`av_display_rotation_get`은 "이 각도만큼 시계방향 회전해야 원본"이라는 의미이므로
     부호를 반전하여 표시 각도로 변환)
  2. **Demuxer.swift**: `VideoStreamInfo`에 `rotation: Double` 필드 추가.
     `displayWidth`/`displayHeight` 계산 프로퍼티 추가 (90/270도일 때 가로세로 swap).
     스트림 파싱 시 `iplayer_get_stream_rotation(stream)` 호출로 회전 값 세팅
  3. **PlayerController.swift**: `MediaInfo`에 `rotation`, `displayWidth`, `displayHeight`
     필드 추가. `buildMediaInfo()`에서 해당 값들 채움
  4. **PlayerView.swift**: `videoRotation` 상태 변수 추가.
     `applyVideoRotation()` 메서드 — `CATransform3DMakeRotation`으로 videoLayer에 회전 적용.
     `layout()` 수정 — rotation이 90/270도일 때 aspect fit 계산을 가로세로 반전하여 수행하고
     `videoLayer.bounds`를 역방향으로 설정하여 회전된 상태에서도 올바른 비율 유지.
     정보 오버레이에 rotation 각도와 실제 표시 해상도(Display) 항목 추가
  5. **iPlayer.swift (AppDelegate)**: `onMediaInfo` 콜백에서 `displayWidth`/`displayHeight`로
     창 비율 계산. 세로 영상(rotation 90/270)일 때 화면 높이의 80%에 맞춰 창 크기 재조정 후
     중앙 배치
- **검증**: Sample 영상(854x480, rotation -90)이 480x854 세로 형태로 올바르게 표시됨.
  Tab 오버레이에서 `Video: h264 854x480 (rot: 90°)`, `Display: 480x854` 확인
