# iPlayer - 비디오 플레이어 개발 명세서

## 프로젝트 개요
macOS용 네이티브 비디오 플레이어. Swift + FFmpeg 8.1 기반.
모든 로컬 비디오 포맷을 재생하며, 하드웨어 가속 디코딩을 우선 사용한다.

## 기술 스택
- **언어**: Swift 6.2
- **UI**: AppKit (NSWindow, NSView, CALayer 기반 렌더링)
- **디코딩**: FFmpeg 8.1 (libavcodec, libavformat, libavutil, libswscale, libswresample)
- **하드웨어 가속**: VideoToolbox (H.264/H.265/VP9/AV1 HW 디코딩)
- **오디오 출력**: AudioToolbox / AVAudioEngine
- **빌드**: Swift Package Manager

## 핵심 기능

### 1. 비디오 디코딩
- FFmpeg demuxer로 컨테이너 파싱 (mp4, mkv, avi, mov, wmv, flv, webm, ts 등)
- 하드웨어 가속 디코딩 우선 (VideoToolbox)
- 실패 시 소프트웨어 디코딩으로 자동 폴백
- pixel format 변환 (swscale) - 다양한 surface format 지원

### 2. 오디오 디코딩 및 출력
- FFmpeg 오디오 디코더 사용
- swresample로 PCM 변환 (Float32, 48kHz 기본)
- AudioToolbox 또는 AVAudioEngine으로 출력
- 볼륨 조절 (0~200%)

### 3. A/V 동기화
- PTS(Presentation Time Stamp) 기반 동기화
- 오디오 클럭을 마스터로 사용
- 비디오 프레임 드롭/대기로 싱크 유지

### 4. 탐색(Seek)
- Seekbar 클릭 시 PTS 기반 정확한 탐색
- 키프레임 탐색 + 정밀 탐색 결합
- 방향키 좌/우로 5초 단위 탐색

### 5. 재생 제어
- 재생 / 일시정지 (Space)
- 정지 (Esc - 처음으로 돌아감)
- 배속 재생 (0.25x ~ 4.0x)
- 프레임 단위 이동 (F키 - 1프레임 전진)

### 6. 단축키
| 키 | 기능 |
|---|---|
| Space | 재생/일시정지 토글 |
| F | 1프레임 전진 |
| ← | 5초 뒤로 |
| → | 5초 앞으로 |
| ↑ | 볼륨 5% 증가 |
| ↓ | 볼륨 5% 감소 |
| [ | 배속 0.25x 감소 |
| ] | 배속 0.25x 증가 |
| Tab | 코덱/FPS 정보 오버레이 토글 |
| M | 음소거 토글 |
| O | 파일 열기 대화상자 |
| R | 렌더 모드 전환 (CVDisplayLink ↔ Thread) |
| D | 프레임 드롭 디버거 토글 |
| Cmd+F | 전체화면 토글 |
| Esc | 전체화면 해제 / 재생 정지 |

### 7. 자막 지원
- SRT 파싱 및 표시
- SMI 파싱 및 표시
- PTS 기반 자막 동기화
- 자막 싱크 조절 (+/- 키)

### 8. 정보 오버레이 (Tab)
- 현재 FPS (실제 렌더링 FPS)
- 비디오 코덱 이름 / 해상도 / 비트레이트
- 오디오 코덱 이름 / 샘플레이트 / 채널 수
- 현재 재생 시간 / 전체 시간
- 디코딩 모드 (HW/SW)
- 드롭 프레임 수

### 9. 추가 기본 기능
- 드래그 앤 드롭으로 파일 열기
- 최근 파일 목록
- 창 크기 자유 조절 (비율 유지)
- 마우스 휠로 볼륨 조절
- 더블클릭 전체화면 토글
- 재생 완료 시 자동 정지
- 트랙 선택 (다중 오디오/자막 트랙)

## 빌드 방법
```bash
cd /Users/ihatego3/Workspace/iPlayer
swift build
swift run iPlayer
```

## FFmpeg 정적 라이브러리
- `Vendor/ffmpeg/`에 FFmpeg 8.1 정적 빌드(.a + 헤더)가 내장되어 있다
- Homebrew 의존 없이 빌드 가능 (시스템 프레임워크만 사용)
- FFmpeg 업그레이드 시 소스에서 최소 구성으로 재빌드:
  - `--enable-static --disable-shared --disable-encoders --disable-muxers --disable-filters --disable-network --disable-avdevice --disable-avfilter --enable-videotoolbox --enable-audiotoolbox`
  - `--extra-cflags="-mmacosx-version-min=14.0"` 필수 (linker warning 방지)

## 버전 관리
- `Version.swift`에서 메이저/마이너/패치 관리
- 브랜치, 커밋 해시, 빌드 번호(커밋 수)는 런타임에 git에서 자동 취득
- 형식: `메이저.마이너.패치.브랜치.커밋해시.빌드번호` (예: `1.0.0.main.e56d836.11`)
- 기능 추가 시 마이너 버전 증가, 구조 변경 시 메이저 버전 증가, 버그 수정 시 패치 증가

## 라이브러리 의존성 정보 (자동 관리)
- "라이브러리 정보" 창은 `Package.swift`를 런타임에 파싱하여 `linkedLibrary`, `linkedFramework` 목록을 자동으로 표시한다
- FFmpeg 라이브러리 버전은 런타임 API(`avcodec_version()` 등)로 자동 취득한다
- **라이브러리/프레임워크를 추가하거나 제거할 때 `Package.swift`만 수정하면 정보 창에 자동 반영된다** — `showLibraryInfo()`를 별도로 수정할 필요 없음
- 새로운 FFmpeg 라이브러리(예: libavfilter)를 추가할 경우, `showLibraryInfo()` 내 `ffmpegVersions` 딕셔너리에 해당 버전 함수를 추가할 것

## 커밋 규칙
- 페이즈별로 빌드 성공 + 기본 기능 확인 후 커밋
- 커밋 메시지는 자연스러운 한국어로 작성
- AI가 작성한 티가 나지 않도록 간결하게
