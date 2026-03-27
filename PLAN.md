# iPlayer 개발 계획

## Phase 1: 프로젝트 기반 구축
- [x] Swift Package Manager 프로젝트 생성
- [x] FFmpeg C 라이브러리 바인딩 (system library target)
- [x] 기본 AppKit 윈도우 + Metal/CALayer 렌더링 뷰
- [x] 빌드 성공 확인
- **커밋**: "프로젝트 초기 구조 및 FFmpeg 바인딩 설정"

## Phase 2: 비디오 디코딩 파이프라인
- [x] FFmpeg demuxer 래퍼 (파일 열기, 스트림 탐색)
- [x] 비디오 디코더 (HW 가속 우선, SW 폴백)
- [x] 프레임을 CVPixelBuffer/CGImage로 변환
- [x] CALayer에 프레임 표시
- [x] 기본 재생 루프 (DisplayLink 기반)
- **커밋**: "비디오 디코딩 및 화면 출력 구현"

## Phase 3: 오디오 디코딩 및 A/V 싱크
- [ ] 오디오 디코더 구현
- [ ] swresample로 PCM 변환
- [ ] AudioToolbox 출력 구현
- [ ] PTS 기반 A/V 동기화 (오디오 마스터 클럭)
- [ ] 볼륨 조절
- **커밋**: "오디오 출력 및 A/V 동기화 구현"

## Phase 4: 재생 제어 및 UI
- [ ] 재생/일시정지/정지
- [ ] Seekbar (PTS 기반 탐색)
- [ ] 배속 재생
- [ ] 프레임 단위 이동 (F키)
- [ ] 시간 표시 (현재/전체)
- [ ] 컨트롤 바 UI
- **커밋**: "재생 제어 UI 및 탐색 기능 구현"

## Phase 5: 단축키 및 정보 오버레이
- [ ] 모든 단축키 바인딩
- [ ] Tab 정보 오버레이 (FPS, 코덱, 해상도 등)
- [ ] 볼륨 OSD
- **커밋**: "단축키 및 코덱 정보 오버레이 추가"

## Phase 6: 자막 지원
- [ ] SRT 파서
- [ ] SMI 파서
- [ ] PTS 기반 자막 렌더링
- [ ] 자막 싱크 조절
- [ ] 자막 트랙 선택
- **커밋**: "SRT/SMI 자막 지원 구현"

## Phase 7: 마무리 및 폴리싱
- [ ] 드래그 앤 드롭
- [ ] 전체화면
- [ ] 창 크기 비율 유지
- [ ] 다중 오디오/자막 트랙 선택
- [ ] 에러 핸들링 강화
- **커밋**: "UX 개선 및 마무리"
