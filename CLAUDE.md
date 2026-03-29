# iPlayer - 비디오 플레이어 개발 명세서

## 프로젝트 개요
macOS용 네이티브 비디오 플레이어. Swift + FFmpeg 8.1 기반.
모든 로컬 비디오 포맷을 재생하며, 하드웨어 가속 디코딩을 우선 사용한다.
AI 분석(9종), 카메라 입력, 3D 얼굴 합성, 가상 옷 입어보기를 지원한다.

## 기술 스택
- **언어**: Swift 6.2
- **UI**: AppKit (NSWindow, NSView, CALayer 기반 렌더링)
- **디코딩**: FFmpeg 8.1 (libavcodec, libavformat, libavutil, libswscale, libswresample)
- **하드웨어 가속**: VideoToolbox (H.264/H.265/VP9/AV1 HW 디코딩)
- **오디오 출력**: AudioToolbox (TimePitch Spectral 알고리즘, 배속 재생)
- **AI 분석**: CoreML + Vision (YOLOv8n, MiDaS, 내장 Vision API 6종)
- **3D 렌더링**: SceneKit (FLAME 얼굴 메시, PBR 조명, MSAA)
- **카메라**: AVFoundation (AVCaptureSession, 좌우 반전 거울 모드)
- **데이터베이스**: SQLite3 (의류 관리)
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
- AudioToolbox TimePitch (Spectral 알고리즘) — 피치 보존 배속 재생
- 볼륨 조절 (0~200%)
- 채널별 레벨 미터 + PCM 파형 표시 (Tab)

### 3. A/V 동기화
- PTS(Presentation Time Stamp) 기반 동기화
- 오디오 클럭을 마스터로 사용
- 비디오 프레임 드롭/대기로 싱크 유지
- 오디오 스톨 감지 시 벽시계 자동 전환

### 4. 탐색(Seek)
- `avformat_seek_file` 비디오 스트림 time_base 기반 정밀 탐색
- seek 후 타겟 이전 오디오 필터링 (클럭 오염 방지)
- `videoDecoderLock` — flush/decode 경합 방지
- 배압 루프 내 seek 요청 즉시 탈출
- 방향키 좌/우로 5초 단위 탐색

### 5. 재생 제어
- 재생 / 일시정지 (Space)
- 정지 (Esc - 처음으로 돌아감)
- 배속 재생 (0.25x ~ 4.0x)
- 고속 최적화: 2~3x 패킷 스킵, >3x 키프레임 전용 디코딩
- 자원 부족 시 버퍼링 스피너 표시 + 오디오 일시정지 + 자동 재개
- 프레임 단위 이동 (F키 - 1프레임 전진)

### 6. 단축키
| 키 | 기능 | 카메라 모드 |
|---|---|---|
| Space | 재생/일시정지 토글 | 비활성 |
| F | 1프레임 전진 | 비활성 |
| ← | 5초 뒤로 | 비활성 |
| → | 5초 앞으로 | 비활성 |
| ↑ | 볼륨 5% 증가 | 비활성 |
| ↓ | 볼륨 5% 감소 | 비활성 |
| [ | 배속 0.25x 감소 | 비활성 |
| ] | 배속 0.25x 증가 | 비활성 |
| Tab | 정보 오버레이 + 리소스 모니터 | **활성** |
| M | 음소거 토글 | 비활성 |
| O | 파일 열기 대화상자 | **활성** |
| R | 렌더 모드 전환 | 비활성 |
| D | 프레임 드롭 디버거 토글 | 비활성 |
| 1/2/3 | 창 크기 50%/100%/200% | **활성** |
| Cmd+F | 전체화면 토글 | **활성** |
| Esc | 전체화면 해제 / 정지 / 카메라 끄기 | **활성** |

### 7. 자막 지원
- SRT 파싱 및 표시
- SMI 파싱 및 표시
- PTS 기반 자막 동기화
- 자막 싱크 조절 (+/- 키)

### 8. 정보 오버레이 (Tab)
- **좌상단**: 코덱/FPS/해상도/비트레이트/동기화 정보
- **우상단**: 리소스 모니터 (메모리, 스레드, 열 상태, 프레임 큐, AI FPS)
- **우하단**: 오디오 채널별 레벨 미터 + PCM 파형 오실로스코프 (파일 모드만)

### 9. 카메라 입력
- 우클릭 → "카메라 입력" → 카메라 장치 선택
- AVFoundation AVCaptureSession 기반 실시간 캡처 (BGRA 32bit)
- 좌우 반전 거울 모드 (`isVideoMirrored`)
- 내장/외장 카메라 자동 감지 및 선택
- 파일 재생과 카메라 간 즉시 전환
- 카메라 종료 시: 버퍼 클리어 + 화면 초기화 + 제목/시간/UI 리셋
- 카메라 모드 UI 완전 분리:
  - 비활성: 컨트롤 바, seekBar, 재생 버튼, 자막, 배속, 볼륨, 오디오 트랙, 렌더 모드, 디버거, 오디오 미터, 마우스 숨김 타이머
  - 비활성 콜백: onTimeUpdate, onSubtitleUpdate, onStateChange, onBuffering
  - 활성: 비디오 영역, AI 분석, 정보 오버레이, 리소스 모니터, 전체화면, 파일 열기

### 10. 추가 기본 기능
- 드래그 앤 드롭으로 파일 열기
- 최근 파일 목록
- 창 크기 자유 조절 (비율 유지)
- 마우스 휠로 볼륨 조절
- 더블클릭 전체화면 토글
- 재생 완료 시 자동 정지
- 트랙 선택 (다중 오디오/자막 트랙)

### 11. AI 분석 (실시간, 9종)
- 우클릭 → "AI 분석" 서브메뉴에서 모드 선택
- **CoreML 모델 (2종)**:
  - **객체 탐지 (YOLOv8n)**: COCO 80클래스, 바운딩 박스 + 레이블
  - **깊이 추정 (MiDaS)**: 단안 깊이맵 Turbo 컬러맵 히트맵
- **Apple Vision 내장 (6종, 모델 파일 불필요)**:
  - **자세 추정 (Pose)**: 15관절 스켈레톤 + 관절점
  - **얼굴 랜드마크**: 76포인트 + 표정 인식 7종 (웃음/놀람/찡그림/윙크 등)
  - **손 추적 (Hand)**: 21관절 × 최대 4손, 손가락별 컬러
  - **텍스트 인식 (OCR)**: 화면 내 텍스트 자동 인식 + 바운딩 박스
  - **인물 분리**: 시안 반투명 인물 마스크 세그멘테이션
  - **옷 입어보기**: 자세 추정 + 손 스와이프 제스처 + 의류 원근 워핑
- **3D 얼굴 합성 (Face Swap)**:
  - FLAME 2023 얼굴 모델 (5023 정점, 9976 삼각형) 내장
  - SceneKit 3D 렌더링 (PBR 조명, 4x MSAA)
  - 4포인트 정렬 (눈+입 → FLAME UV 매칭, 수평/수직 독립 스케일)
  - 머리 포즈 추정 (roll/yaw/pitch) → 3D 원근 워핑
  - .obj/.usdz 외부 3D 모델 로드 지원
- 자원 경합 시 탐지 자동 보류 (비디오 우선, 상태 배지 표시)
- seek 시 결과 즉시 클리어 + seekGeneration으로 stale 추론 폐기
- 카메라 피드에도 동일하게 적용

### 12. 옷 입어보기
- 우클릭 → AI 분석 → "옷 입어보기"
- 자세 추정(15관절) 위에 의류 2D PNG를 관절 4점 원근 워핑
- 손 스와이프 제스처로 옷 변경 (좌→우: 다음, 우→좌: 이전)
- 의류 타입별 신체 매핑: 모자→머리, 상의→어깨~엉덩이, 하의→엉덩이~발목, 전신→어깨~발목
- SQLite DB에서 활성(착용) 의류 로드
- 스와이프 감지: wrist x 이동량 > 25%, 쿨다운 1초, 양손 지원

### 13. 옷장 관리 (SQLite)
- 메뉴: 도구 → "옷장 관리..." 또는 우클릭 → "옷장 관리..."
- SQLite 데이터베이스: `~/Library/Application Support/iPlayer/clothing.db`
- 스키마: id, name, type, color_hex, opacity, pattern, model_file, notes, created_at, is_active
- 의류 타입: 상의, 하의, 원피스, 모자, 액세서리
- UI: 테이블 뷰 (착용 체크박스, 3D 미리보기, 이름, 종류, 모델 파일, 색상, 메모)
- 기능: 추가/삭제, 타입 필터, 인라인 편집, 착용 토글
- 3D 미리보기: 비동기 렌더 + 캐시 (메인 스레드 블로킹 방지)
- 첫 실행 시 MakeHuman 의류 6벌 자동 생성

## AI 모델 관리
- 내장 모델: `Sources/iPlayer/Resources/` 하위
  - `YOLOv8n.mlmodelc` (6.2MB) — 객체 탐지
  - `YOLOv3Tiny.mlmodelc` (34MB) — 객체 탐지 (폴백)
  - `MiDaSSmall.mlmodelc` (32MB) — 깊이 추정
  - `flame_face.obj` (550KB) — FLAME 2023 3D 얼굴 메시 (정면 투영 UV)
  - `face_mesh.obj` (218KB) — 절차적 3D 얼굴 메시 (폴백)
  - `clothes/` — MakeHuman 3D 의류 6종 (OBJ + 사전 렌더 PNG)
    - tshirt, suit, dress, casual2, sportswear, fedora

## 의류 렌더링 파이프라인
1. **사전 렌더**: OBJ → SceneKit 정면 렌더 → 512x640 PNG (빌드 시 1회)
2. **런타임 로드**: PNG 캐시 로드 (모델당 1회)
3. **관절 감지**: VNDetectHumanBodyPoseRequest (15관절)
4. **4점 결정**: 의류 타입에 따라 어깨/엉덩이/발목 등 4점 선택
5. **원근 워핑**: CIPerspectiveTransform으로 PNG를 4점에 맞춤
6. **색상 틴트**: CIColorMatrix로 SQLite 색상 적용
7. **합성**: CALayer draw에서 워핑된 이미지 오버레이

## 3D 얼굴 합성 파이프라인
1. **참조 이미지 로드** → Vision 랜드마크 추출 (눈/코/입 위치)
2. **4포인트 정렬** → 눈 간 거리(수평 스케일) + 눈→입 거리(수직 스케일) 독립 계산
3. **정렬 텍스처 생성** → CIImage 아핀 변환 → 1024x1024 크롭
4. **FLAME 메시 매핑** → SceneKit에서 텍스처 적용 (Phong 조명)
5. **머리 포즈 추정** → 비디오 프레임의 눈/코 위치에서 roll/yaw/pitch 계산
6. **3D 렌더링** → SceneKit eulerAngles 회전 → 512x512 MSAA 렌더
7. **합성** → 비디오 얼굴 bbox 확장 (+35% 상, +15% 하/좌/우) → 타원 마스크 블렌딩

## 배속 최적화 전략
| 배속 | 비디오 디코딩 | 배압 | 프레임 선택 |
|------|------------|------|-----------|
| ≤2.0x | 모든 프레임 | 대기 | 정밀 동기화 |
| 2.0~3.0x | 2프레임 중 1프레임 스킵 | 드롭 (>2.5x) | 가장 가까운 프레임 |
| >3.0x | 키프레임만 | 드롭 | 가장 가까운 프레임 |

## 검증 도구
- `Tools/clothing_debug.swift` — 의류 매핑 좌표 검증
  - 15관절 시각화 (번호 + 색상 코딩)
  - 스켈레톤 연결선
  - 의류 타입별 매핑 영역 표시 (모자/상의/하의)
  - Y축 방향 검증
  - 사용: `swift Tools/clothing_debug.swift [이미지] [출력폴더]`

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

## 라이브러리 의존성 (자동 관리)
- "라이브러리 정보" 창은 `Package.swift`를 런타임에 파싱하여 `linkedLibrary`, `linkedFramework` 목록을 자동으로 표시한다
- FFmpeg 라이브러리 버전은 런타임 API(`avcodec_version()` 등)로 자동 취득한다
- **라이브러리/프레임워크를 추가하거나 제거할 때 `Package.swift`만 수정하면 정보 창에 자동 반영된다**
- 현재 링크된 프레임워크:
  - FFmpeg: avcodec, avformat, avutil, swscale, swresample
  - 시스템: z, bz2, iconv, sqlite3
  - Apple: VideoToolbox, CoreMedia, CoreVideo, CoreFoundation, CoreServices, AudioToolbox, CoreAudio, AppKit, QuartzCore, Security, CoreML, Vision, AVFoundation, SceneKit, ModelIO

## 커밋 규칙
- 페이즈별로 빌드 성공 + 기본 기능 확인 후 커밋
- 커밋 메시지는 자연스러운 한국어로 작성
- AI가 작성한 티가 나지 않도록 간결하게
