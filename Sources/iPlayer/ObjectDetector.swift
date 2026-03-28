import Foundation
import Vision
import CoreML
import CoreVideo
import AppKit
import QuartzCore

// MARK: - 모델 타입

enum DetectorMode: String, CaseIterable {
    case objectDetection = "객체 탐지 (YOLOv8n)"
    case pose = "자세 추정 (Pose)"
    case depth = "깊이 추정 (MiDaS)"
    case faceLandmarks = "얼굴 랜드마크"
    case handPose = "손 추적 (Hand)"
    case textRecognition = "텍스트 인식 (OCR)"
    case personSegmentation = "인물 분리"
    case faceSwap = "얼굴 합성 (Face Swap)"

    var isBuiltIn: Bool {
        switch self {
        case .pose, .faceLandmarks, .handPose, .textRecognition, .personSegmentation, .faceSwap: return true
        case .objectDetection, .depth: return false
        }
    }
}

// MARK: - 결과 타입

struct DetectedObject {
    let label: String
    let confidence: Float
    let boundingBox: CGRect
}

struct PoseJoint {
    let name: String
    let location: CGPoint
    let confidence: Float
}

struct PoseResult {
    let joints: [PoseJoint]
    let connections: [(Int, Int)]
}

enum FaceExpression: String {
    case neutral = "무표정"
    case smile = "웃음 😊"
    case surprise = "놀람 😮"
    case frown = "찡그림 😠"
    case mouthOpen = "입 벌림 😲"
    case winkLeft = "왼쪽 윙크 😉"
    case winkRight = "오른쪽 윙크 😉"
}

struct FaceResult {
    let boundingBox: CGRect
    let landmarks: [CGPoint]
    let faceContour: [CGPoint]
    let leftEye: [CGPoint]
    let rightEye: [CGPoint]
    let nose: [CGPoint]
    let outerLips: [CGPoint]
    let leftEyebrow: [CGPoint]
    let rightEyebrow: [CGPoint]
    let innerLips: [CGPoint]
    let expression: FaceExpression
}

struct HandResult {
    let joints: [PoseJoint]
    let connections: [(Int, Int)]
}

struct TextResult {
    let text: String
    let confidence: Float
    let boundingBox: CGRect
}

enum DetectionState { case idle, detecting, deferred }

struct FaceSwapEntry {
    let warpedFace: CGImage
    let targetRect: CGRect  // 정규화 좌표
    let maskRect: CGRect    // 타원 마스크 영역
}

enum DetectionResult {
    case objects([DetectedObject])
    case poses([PoseResult])
    case depthMap(CGImage)
    case faces([FaceResult])
    case hands([HandResult])
    case texts([TextResult])
    case segmentation(CGImage)
    case faceSwap([FaceSwapEntry])
    case empty
}

// MARK: - ObjectDetector

final class ObjectDetector: @unchecked Sendable {
    private var vnModel: VNCoreMLModel?
    private var depthModel: VNCoreMLModel?
    private let detectionQueue = DispatchQueue(label: "iPlayer.ObjectDetection", qos: .utility)

    // 얼굴 합성용 참조 이미지
    private var referenceFace: CGImage?
    private var referenceLandmarks: (leftEye: CGPoint, rightEye: CGPoint)?  // 정규화 좌표
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private let resultsLock = NSLock()
    private var _latestResult: DetectionResult = .empty
    var latestResult: DetectionResult {
        resultsLock.lock()
        let r = _latestResult
        resultsLock.unlock()
        return r
    }

    var mode: DetectorMode = .objectDetection
    private(set) var isLoaded = false
    private var isBusy = false
    private var seekGeneration: Int = 0
    private var frameSkipCounter = 0
    var confidenceThreshold: Float = 0.5
    var isEnabled = false

    private let queueDepthHealthy = 30
    private let queueDepthReduced = 15

    private(set) var state: DetectionState = .idle
    private(set) var detectionFPS: Double = 0
    private var fpsCounter = 0
    private var fpsTimerStart: Double = 0

    var onDetectionUpdate: (() -> Void)?

    // MARK: - 얼굴 합성 참조 설정

    func setReferenceFace(image: NSImage) {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            log("[FaceSwap] 이미지 변환 실패"); return
        }
        // 참조 이미지에서 얼굴 랜드마크 추출
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let req = VNDetectFaceLandmarksRequest()
        try? handler.perform([req])

        guard let face = req.results?.first,
              let lm = face.landmarks,
              let le = lm.leftEye, le.pointCount > 0,
              let re = lm.rightEye, re.pointCount > 0 else {
            log("[FaceSwap] 참조 이미지에서 얼굴 감지 실패"); return
        }

        // 눈 중심 계산 (얼굴 bbox 내 정규화 좌표)
        let leCenter = (0..<le.pointCount).reduce(CGPoint.zero) { CGPoint(x: $0.x + le.normalizedPoints[$1].x, y: $0.y + le.normalizedPoints[$1].y) }
        let reCenter = (0..<re.pointCount).reduce(CGPoint.zero) { CGPoint(x: $0.x + re.normalizedPoints[$1].x, y: $0.y + re.normalizedPoints[$1].y) }
        let leN = CGFloat(le.pointCount), reN = CGFloat(re.pointCount)

        referenceFace = cgImage
        referenceLandmarks = (
            leftEye: CGPoint(x: leCenter.x / leN, y: leCenter.y / leN),
            rightEye: CGPoint(x: reCenter.x / reN, y: reCenter.y / reN)
        )

        // 참조 이미지를 얼굴 영역만 크롭
        let bbox = face.boundingBox
        let cropRect = CGRect(
            x: bbox.origin.x * CGFloat(cgImage.width),
            y: (1 - bbox.origin.y - bbox.height) * CGFloat(cgImage.height),
            width: bbox.width * CGFloat(cgImage.width),
            height: bbox.height * CGFloat(cgImage.height)
        )
        if let cropped = cgImage.cropping(to: cropRect) {
            referenceFace = cropped
        }

        log("[FaceSwap] 참조 얼굴 설정 완료 (\(cgImage.width)x\(cgImage.height))")
    }

    var hasReferenceFace: Bool { referenceFace != nil }

    // MARK: - 모델 로드

    func loadModel(for newMode: DetectorMode) {
        mode = newMode

        if newMode.isBuiltIn {
            isLoaded = true
            log("[ObjectDetector] \(newMode.rawValue) (Apple Vision 내장)")
            return
        }

        let modelName: String
        switch newMode {
        case .objectDetection: modelName = "YOLOv8n"
        case .depth: modelName = "MiDaSSmall"
        default: return
        }

        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let url = self.findModelURL(name: modelName) else {
                if newMode == .objectDetection, let fb = self.findModelURL(name: "YOLOv3Tiny") {
                    self.loadCoreML(from: fb, forDepth: false); return
                }
                log("[ObjectDetector] \(modelName) 모델 없음"); return
            }
            self.loadCoreML(from: url, forDepth: newMode == .depth)
        }
    }

    private func loadCoreML(from url: URL, forDepth: Bool) {
        do {
            let compiled = url.pathExtension == "mlmodelc" ? url : try MLModel.compileModel(at: url)
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let ml = try MLModel(contentsOf: compiled, configuration: config)
            let vn = try VNCoreMLModel(for: ml)
            if forDepth { depthModel = vn } else { vnModel = vn }
            isLoaded = true
            log("[ObjectDetector] \(url.lastPathComponent) 로드 완료")
        } catch {
            log("[ObjectDetector] 로드 실패: \(error)")
        }
    }

    // MARK: - 프레임 처리

    func processFrame(_ pixelBuffer: CVPixelBuffer, queueDepth: Int) {
        guard isEnabled, isLoaded, !isBusy else { return }

        if queueDepth >= queueDepthHealthy {
            // 매 프레임
        } else if queueDepth >= queueDepthReduced {
            frameSkipCounter += 1
            guard frameSkipCounter >= 3 else { return }
            frameSkipCounter = 0
        } else {
            state = .deferred; return
        }

        isBusy = true
        state = .detecting
        let gen = seekGeneration
        let m = mode
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isBusy = false }
            guard gen == self.seekGeneration else { return }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            self.runMode(m, handler: handler, gen: gen)
            self.measureFPS()
        }
    }

    func processFrame(_ cgImage: CGImage, queueDepth: Int) {
        guard isEnabled, isLoaded, !isBusy else { return }

        if queueDepth >= queueDepthHealthy {
        } else if queueDepth >= queueDepthReduced {
            frameSkipCounter += 1
            guard frameSkipCounter >= 3 else { return }
            frameSkipCounter = 0
        } else {
            state = .deferred; return
        }

        isBusy = true
        state = .detecting
        let gen = seekGeneration
        let m = mode
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isBusy = false }
            guard gen == self.seekGeneration else { return }
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            self.runMode(m, handler: handler, gen: gen)
            self.measureFPS()
        }
    }

    private func runMode(_ mode: DetectorMode, handler: VNImageRequestHandler, gen: Int) {
        switch mode {
        case .objectDetection: runObjectDetection(handler: handler, gen: gen)
        case .pose:            runPoseEstimation(handler: handler, gen: gen)
        case .depth:           runDepthEstimation(handler: handler, gen: gen)
        case .faceLandmarks:   runFaceLandmarks(handler: handler, gen: gen)
        case .handPose:        runHandPose(handler: handler, gen: gen)
        case .textRecognition: runTextRecognition(handler: handler, gen: gen)
        case .personSegmentation: runPersonSegmentation(handler: handler, gen: gen)
        case .faceSwap:          runFaceSwap(handler: handler, gen: gen)
        }
    }

    func reset() {
        seekGeneration += 1
        isBusy = false
        frameSkipCounter = 0
        state = .idle
        detectionFPS = 0
        fpsCounter = 0
        resultsLock.lock()
        _latestResult = .empty
        resultsLock.unlock()
    }

    // MARK: - 객체 탐지 (YOLO)

    private func runObjectDetection(handler: VNImageRequestHandler, gen: Int) {
        guard let model = vnModel else { return }
        let req = VNCoreMLRequest(model: model) { [weak self] r, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            guard let obs = r.results as? [VNRecognizedObjectObservation] else { self.setResult(.objects([])); return }
            let filtered = obs.filter { $0.confidence >= self.confidenceThreshold }
                .map { DetectedObject(label: $0.labels.first?.identifier ?? "?", confidence: $0.confidence, boundingBox: $0.boundingBox) }
            self.setResult(.objects(filtered))
        }
        req.imageCropAndScaleOption = .scaleFill
        try? handler.perform([req])
    }

    // MARK: - 자세 추정 (Body Pose)

    private static let bodyJointNames: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .neck, .leftShoulder, .rightShoulder, .leftElbow, .rightElbow,
        .leftWrist, .rightWrist, .root, .leftHip, .rightHip, .leftKnee, .rightKnee,
        .leftAnkle, .rightAnkle,
    ]
    private static let bodyConnections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .neck), (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root), (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    private func runPoseEstimation(handler: VNImageRequestHandler, gen: Int) {
        let req = VNDetectHumanBodyPoseRequest { [weak self] r, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            guard let obs = r.results as? [VNHumanBodyPoseObservation] else { self.setResult(.poses([])); return }
            let poses = obs.map { self.buildPose($0) }
            self.setResult(.poses(poses))
        }
        try? handler.perform([req])
    }

    private func buildPose(_ obs: VNHumanBodyPoseObservation) -> PoseResult {
        let names = Self.bodyJointNames
        var joints = [PoseJoint]()
        for n in names {
            if let pt = try? obs.recognizedPoint(n), pt.confidence > 0.1 {
                joints.append(PoseJoint(name: n.rawValue.rawValue, location: pt.location, confidence: Float(pt.confidence)))
            } else {
                joints.append(PoseJoint(name: n.rawValue.rawValue, location: .zero, confidence: 0))
            }
        }
        var conns = [(Int, Int)]()
        for (from, to) in Self.bodyConnections {
            if let fi = names.firstIndex(of: from), let ti = names.firstIndex(of: to),
               joints[fi].confidence > 0.1 && joints[ti].confidence > 0.1 {
                conns.append((fi, ti))
            }
        }
        return PoseResult(joints: joints, connections: conns)
    }

    // MARK: - 얼굴 랜드마크

    private func runFaceLandmarks(handler: VNImageRequestHandler, gen: Int) {
        let req = VNDetectFaceLandmarksRequest { [weak self] r, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            guard let obs = r.results as? [VNFaceObservation] else { self.setResult(.faces([])); return }
            let faces = obs.compactMap { self.buildFace($0) }
            self.setResult(.faces(faces))
        }
        try? handler.perform([req])
    }

    private func buildFace(_ obs: VNFaceObservation) -> FaceResult? {
        guard let lm = obs.landmarks else { return nil }
        func pts(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let r = region else { return [] }
            return (0..<r.pointCount).map { r.normalizedPoints[$0] }
        }
        let leftEye = pts(lm.leftEye)
        let rightEye = pts(lm.rightEye)
        let outerLips = pts(lm.outerLips)
        let innerLips = pts(lm.innerLips)
        let leftEyebrow = pts(lm.leftEyebrow)
        let rightEyebrow = pts(lm.rightEyebrow)

        let expression = analyzeExpression(
            leftEye: leftEye, rightEye: rightEye,
            outerLips: outerLips, innerLips: innerLips,
            leftEyebrow: leftEyebrow, rightEyebrow: rightEyebrow
        )

        return FaceResult(
            boundingBox: obs.boundingBox,
            landmarks: pts(lm.allPoints),
            faceContour: pts(lm.faceContour),
            leftEye: leftEye, rightEye: rightEye,
            nose: pts(lm.nose), outerLips: outerLips,
            leftEyebrow: leftEyebrow, rightEyebrow: rightEyebrow,
            innerLips: innerLips, expression: expression
        )
    }

    // MARK: - 표정 분석 (랜드마크 기하학)

    private func analyzeExpression(
        leftEye: [CGPoint], rightEye: [CGPoint],
        outerLips: [CGPoint], innerLips: [CGPoint],
        leftEyebrow: [CGPoint], rightEyebrow: [CGPoint]
    ) -> FaceExpression {
        // 눈 개폐 비율 (높이/너비)
        let leftEyeAR = eyeAspectRatio(leftEye)
        let rightEyeAR = eyeAspectRatio(rightEye)

        // 윙크 감지
        if leftEyeAR < 0.15 && rightEyeAR > 0.25 { return .winkLeft }
        if rightEyeAR < 0.15 && leftEyeAR > 0.25 { return .winkRight }

        // 입 개폐 비율
        let mouthAR = mouthAspectRatio(outerLips)
        let innerMouthAR = mouthAspectRatio(innerLips)

        // 입 너비 비율 (웃음 감지용)
        let mouthWidth = mouthWidthRatio(outerLips)

        // 눈썹 높이 (놀람 감지용)
        let browHeight = eyebrowHeight(leftEyebrow: leftEyebrow, rightEyebrow: rightEyebrow,
                                        leftEye: leftEye, rightEye: rightEye)

        // 입 크게 벌림
        if innerMouthAR > 0.5 && mouthAR > 0.4 {
            // 눈도 크면 놀람, 아니면 입 벌림
            if browHeight > 0.35 && leftEyeAR > 0.3 && rightEyeAR > 0.3 {
                return .surprise
            }
            return .mouthOpen
        }

        // 놀람: 눈썹 올라감 + 눈 크게 뜸
        if browHeight > 0.35 && leftEyeAR > 0.32 && rightEyeAR > 0.32 {
            return .surprise
        }

        // 웃음: 입꼬리 올라감 + 입 넓어짐
        if mouthWidth > 0.55 && mouthAR < 0.35 {
            return .smile
        }

        // 찡그림: 눈썹 내려감 + 입꼬리 내려감
        if browHeight < 0.18 && mouthWidth < 0.42 {
            return .frown
        }

        return .neutral
    }

    /// 눈 종횡비 (Eye Aspect Ratio) — 감긴 눈 < 0.2, 뜬 눈 > 0.25
    private func eyeAspectRatio(_ eye: [CGPoint]) -> CGFloat {
        guard eye.count >= 6 else { return 0.25 }
        // 눈 포인트: 0=안쪽, 1-2=위, 3=바깥, 4-5=아래 (대략적)
        let h1 = abs(eye[1].y - eye[5].y)
        let h2 = abs(eye[2].y - eye[4].y)
        let w = abs(eye[3].x - eye[0].x)
        guard w > 0 else { return 0.25 }
        return (h1 + h2) / (2.0 * w)
    }

    /// 입 종횡비 — 다문 입 < 0.2, 벌린 입 > 0.4
    private func mouthAspectRatio(_ lips: [CGPoint]) -> CGFloat {
        guard lips.count >= 8 else { return 0.2 }
        let top = lips[lips.count / 4]        // 상순 중앙 부근
        let bottom = lips[lips.count * 3 / 4]  // 하순 중앙 부근
        let left = lips[0]
        let right = lips[lips.count / 2]
        let h = abs(top.y - bottom.y)
        let w = abs(right.x - left.x)
        guard w > 0 else { return 0.2 }
        return h / w
    }

    /// 입 너비 비율 (얼굴 대비) — 웃을 때 > 0.55
    private func mouthWidthRatio(_ lips: [CGPoint]) -> CGFloat {
        guard lips.count >= 4 else { return 0.45 }
        let left = lips[0]
        let right = lips[lips.count / 2]
        return abs(right.x - left.x)
    }

    /// 눈썹-눈 거리 비율 — 놀람 > 0.35, 찡그림 < 0.18
    private func eyebrowHeight(leftEyebrow: [CGPoint], rightEyebrow: [CGPoint],
                                leftEye: [CGPoint], rightEye: [CGPoint]) -> CGFloat {
        guard !leftEyebrow.isEmpty, !rightEyebrow.isEmpty,
              !leftEye.isEmpty, !rightEye.isEmpty else { return 0.25 }
        let lbCenter = leftEyebrow[leftEyebrow.count / 2].y
        let rbCenter = rightEyebrow[rightEyebrow.count / 2].y
        let leCenter = leftEye.reduce(0.0) { $0 + $1.y } / CGFloat(leftEye.count)
        let reCenter = rightEye.reduce(0.0) { $0 + $1.y } / CGFloat(rightEye.count)
        let leftDist = lbCenter - leCenter
        let rightDist = rbCenter - reCenter
        return (leftDist + rightDist) / 2.0
    }

    // MARK: - 손 추적

    private static let handJointNames: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip,
    ]
    private static let handConnections: [(Int, Int)] = [
        (0,1),(1,2),(2,3),(3,4),  // thumb
        (0,5),(5,6),(6,7),(7,8),  // index
        (0,9),(9,10),(10,11),(11,12),  // middle
        (0,13),(13,14),(14,15),(15,16),  // ring
        (0,17),(17,18),(18,19),(19,20),  // little
    ]

    private func runHandPose(handler: VNImageRequestHandler, gen: Int) {
        let req = VNDetectHumanHandPoseRequest { [weak self] r, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            guard let obs = r.results as? [VNHumanHandPoseObservation] else { self.setResult(.hands([])); return }
            let hands = obs.map { self.buildHand($0) }
            self.setResult(.hands(hands))
        }
        req.maximumHandCount = 4
        try? handler.perform([req])
    }

    private func buildHand(_ obs: VNHumanHandPoseObservation) -> HandResult {
        let names = Self.handJointNames
        var joints = [PoseJoint]()
        for n in names {
            if let pt = try? obs.recognizedPoint(n), pt.confidence > 0.1 {
                joints.append(PoseJoint(name: n.rawValue.rawValue, location: pt.location, confidence: Float(pt.confidence)))
            } else {
                joints.append(PoseJoint(name: n.rawValue.rawValue, location: .zero, confidence: 0))
            }
        }
        var conns = [(Int, Int)]()
        for (fi, ti) in Self.handConnections {
            if joints[fi].confidence > 0.1 && joints[ti].confidence > 0.1 {
                conns.append((fi, ti))
            }
        }
        return HandResult(joints: joints, connections: conns)
    }

    // MARK: - 텍스트 인식 (OCR)

    private func runTextRecognition(handler: VNImageRequestHandler, gen: Int) {
        let req = VNRecognizeTextRequest { [weak self] r, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            guard let obs = r.results as? [VNRecognizedTextObservation] else { self.setResult(.texts([])); return }
            let texts = obs.compactMap { ob -> TextResult? in
                guard let top = ob.topCandidates(1).first else { return nil }
                return TextResult(text: top.string, confidence: top.confidence, boundingBox: ob.boundingBox)
            }
            self.setResult(.texts(texts))
        }
        req.recognitionLevel = .fast
        req.automaticallyDetectsLanguage = true
        try? handler.perform([req])
    }

    // MARK: - 인물 분리 (Person Segmentation)

    private func runPersonSegmentation(handler: VNImageRequestHandler, gen: Int) {
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        try? handler.perform([req])
        guard gen == seekGeneration,
              let result = req.results?.first,
              let image = segmentationToImage(result.pixelBuffer) else {
            setResult(.empty); return
        }
        setResult(.segmentation(image))
    }

    private func segmentationToImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let src = baseAddr.assumingMemoryBound(to: UInt8.self)

        // 1채널 마스크 → RGBA (인물=시안 반투명, 배경=투명)
        var pixelData = Data(count: w * h * 4)
        pixelData.withUnsafeMutableBytes { rawBuf in
            let dst = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    let mask = src[y * bytesPerRow + x]
                    let idx = (y * w + x) * 4
                    if mask > 128 {
                        dst[idx] = 0; dst[idx+1] = 200; dst[idx+2] = 220; dst[idx+3] = 100
                    } else {
                        dst[idx] = 0; dst[idx+1] = 0; dst[idx+2] = 0; dst[idx+3] = 0
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: - 깊이 추정 (MiDaS)

    private func runDepthEstimation(handler: VNImageRequestHandler, gen: Int) {
        guard let model = depthModel else { return }
        let req = VNCoreMLRequest(model: model) { [weak self] r, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            guard let obs = r.results as? [VNCoreMLFeatureValueObservation],
                  let arr = obs.first?.featureValue.multiArrayValue,
                  let img = self.depthArrayToImage(arr) else { self.setResult(.empty); return }
            self.setResult(.depthMap(img))
        }
        req.imageCropAndScaleOption = .scaleFill
        try? handler.perform([req])
    }

    private func depthArrayToImage(_ array: MLMultiArray) -> CGImage? {
        let shape = array.shape.map { $0.intValue }
        guard shape.count >= 2 else { return nil }
        let h = shape[shape.count - 2]
        let w = shape[shape.count - 1]
        let count = w * h
        guard count > 0 else { return nil }

        var values = [Float](repeating: 0, count: count)
        for i in 0..<count { values[i] = array[i].floatValue }

        var minVal: Float = .greatestFiniteMagnitude, maxVal: Float = -.greatestFiniteMagnitude
        for v in values { if v < minVal { minVal = v }; if v > maxVal { maxVal = v } }
        let range = maxVal - minVal
        guard range > 0 else { return nil }

        var pixelData = Data(count: count * 4)
        pixelData.withUnsafeMutableBytes { rawBuf in
            let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<count {
                let norm = (values[i] - minVal) / range
                let (r, g, b) = depthToColor(norm)
                ptr[i*4] = r; ptr[i*4+1] = g; ptr[i*4+2] = b; ptr[i*4+3] = 160
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: w * 4, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    private func depthToColor(_ value: Float) -> (UInt8, UInt8, UInt8) {
        let t = max(0, min(1, value))
        let r, g, b: Float
        if t < 0.25      { let s = t/0.25;       r=0; g=s; b=1 }
        else if t < 0.5   { let s = (t-0.25)/0.25; r=0; g=1; b=1-s }
        else if t < 0.75  { let s = (t-0.5)/0.25;  r=s; g=1; b=0 }
        else               { let s = (t-0.75)/0.25; r=1; g=1-s; b=0 }
        return (UInt8(r*255), UInt8(g*255), UInt8(b*255))
    }

    // MARK: - 얼굴 합성 (Face Swap)

    private func runFaceSwap(handler: VNImageRequestHandler, gen: Int) {
        guard let refFace = referenceFace else {
            setResult(.empty); return
        }

        let req = VNDetectFaceLandmarksRequest()
        try? handler.perform([req])
        guard gen == seekGeneration,
              let observations = req.results, !observations.isEmpty else {
            setResult(.faceSwap([])); return
        }

        var entries: [FaceSwapEntry] = []
        for obs in observations {
            guard let lm = obs.landmarks,
                  let le = lm.leftEye, le.pointCount > 0,
                  let re = lm.rightEye, re.pointCount > 0 else { continue }

            // 비디오 얼굴의 눈 중심 (얼굴 bbox 내 정규화)
            let leC = eyeCenter(le)
            let reC = eyeCenter(re)

            // 비디오 상 절대 좌표로 변환
            let bbox = obs.boundingBox
            let videoLeAbs = CGPoint(x: bbox.origin.x + leC.x * bbox.width,
                                      y: bbox.origin.y + leC.y * bbox.height)
            let videoReAbs = CGPoint(x: bbox.origin.x + reC.x * bbox.width,
                                      y: bbox.origin.y + reC.y * bbox.height)

            // 워핑: 참조 얼굴을 비디오 얼굴 위치/크기/회전에 맞춤
            if let warped = warpReferenceFace(refFace, to: bbox,
                                              videoLeftEye: videoLeAbs, videoRightEye: videoReAbs) {
                // 마스크 영역: 얼굴 bbox보다 약간 안쪽
                let inset: CGFloat = 0.08
                let maskRect = CGRect(x: bbox.origin.x + bbox.width * inset,
                                       y: bbox.origin.y + bbox.height * inset,
                                       width: bbox.width * (1 - inset * 2),
                                       height: bbox.height * (1 - inset * 2))
                entries.append(FaceSwapEntry(warpedFace: warped, targetRect: bbox, maskRect: maskRect))
            }
        }
        setResult(.faceSwap(entries))
    }

    private func eyeCenter(_ eye: VNFaceLandmarkRegion2D) -> CGPoint {
        var sum = CGPoint.zero
        for i in 0..<eye.pointCount {
            sum.x += eye.normalizedPoints[i].x
            sum.y += eye.normalizedPoints[i].y
        }
        let n = CGFloat(eye.pointCount)
        return CGPoint(x: sum.x / n, y: sum.y / n)
    }

    private func warpReferenceFace(_ refFace: CGImage, to targetBox: CGRect,
                                    videoLeftEye: CGPoint, videoRightEye: CGPoint) -> CGImage? {
        let refW = CGFloat(refFace.width)
        let refH = CGFloat(refFace.height)

        // CIImage로 변환
        let ciRef = CIImage(cgImage: refFace)

        // 비디오 눈 간 거리와 각도
        let videoDx = videoRightEye.x - videoLeftEye.x
        let videoDy = videoRightEye.y - videoLeftEye.y
        let videoEyeDist = sqrt(videoDx * videoDx + videoDy * videoDy)
        let videoAngle = atan2(videoDy, videoDx)

        // 참조 눈 간 거리 (참조 이미지가 얼굴만 크롭된 상태이므로 기본 비율 사용)
        let refEyeDist = refW * 0.35  // 얼굴 너비의 ~35%가 눈 간 거리

        guard videoEyeDist > 0 && refEyeDist > 0 else { return nil }

        // 스케일: 비디오 얼굴 크기에 맞춤 (약간 확대하여 가장자리 커버)
        let scale = (targetBox.width * 1.1) / (refW / refW)  // bbox 기준
        let scaleX = targetBox.width * 1.1
        let scaleY = targetBox.height * 1.1

        // 아핀 변환 적용
        var transform = CGAffineTransform.identity
        // 1. 참조 이미지를 원점 중심으로 이동
        transform = transform.translatedBy(x: -refW / 2, y: -refH / 2)
        // 2. 스케일
        transform = transform.scaledBy(x: scaleX / refW, y: scaleY / refH)
        // 3. 회전
        transform = transform.rotated(by: videoAngle)

        let transformed = ciRef.transformed(by: transform)

        // 렌더링 크기 (큰 해상도 불필요, 얼굴 영역 크기로 충분)
        let outW = Int(max(100, scaleX * 500))
        let outH = Int(max(100, scaleY * 500))
        let renderRect = CGRect(x: transformed.extent.midX - CGFloat(outW) / 2,
                                 y: transformed.extent.midY - CGFloat(outH) / 2,
                                 width: CGFloat(outW), height: CGFloat(outH))

        guard let cgResult = ciContext.createCGImage(transformed, from: renderRect) else { return nil }
        return cgResult
    }

    // MARK: - 공통

    private func setResult(_ result: DetectionResult) {
        resultsLock.lock()
        _latestResult = result
        resultsLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.onDetectionUpdate?() }
    }

    private func measureFPS() {
        fpsCounter += 1
        let now = CACurrentMediaTime()
        if fpsTimerStart == 0 { fpsTimerStart = now }
        let elapsed = now - fpsTimerStart
        if elapsed >= 1.0 { detectionFPS = Double(fpsCounter) / elapsed; fpsCounter = 0; fpsTimerStart = now }
    }

    private func findModelURL(name: String) -> URL? {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        if let bundle = Bundle(url: execURL.appendingPathComponent("iPlayer_iPlayer.bundle")) {
            for ext in ["mlmodelc", "mlmodel"] {
                if let url = bundle.url(forResource: name, withExtension: ext) { return url }
            }
        }
        for dir in [execURL.appendingPathComponent("Resources"),
                    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources")] {
            for ext in ["mlmodelc", "mlmodel"] {
                let url = dir.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }
}
