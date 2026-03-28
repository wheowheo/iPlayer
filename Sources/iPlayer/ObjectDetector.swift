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

    var isBuiltIn: Bool {
        switch self {
        case .pose, .faceLandmarks, .handPose, .textRecognition, .personSegmentation: return true
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

struct FaceResult {
    let boundingBox: CGRect
    let landmarks: [CGPoint]    // 정규화 좌표 (얼굴 bbox 기준)
    let faceContour: [CGPoint]
    let leftEye: [CGPoint]
    let rightEye: [CGPoint]
    let nose: [CGPoint]
    let outerLips: [CGPoint]
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

enum DetectionResult {
    case objects([DetectedObject])
    case poses([PoseResult])
    case depthMap(CGImage)
    case faces([FaceResult])
    case hands([HandResult])
    case texts([TextResult])
    case segmentation(CGImage)
    case empty
}

// MARK: - ObjectDetector

final class ObjectDetector: @unchecked Sendable {
    private var vnModel: VNCoreMLModel?
    private var depthModel: VNCoreMLModel?
    private let detectionQueue = DispatchQueue(label: "iPlayer.ObjectDetection", qos: .utility)

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
        return FaceResult(
            boundingBox: obs.boundingBox,
            landmarks: pts(lm.allPoints),
            faceContour: pts(lm.faceContour),
            leftEye: pts(lm.leftEye),
            rightEye: pts(lm.rightEye),
            nose: pts(lm.nose),
            outerLips: pts(lm.outerLips)
        )
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
