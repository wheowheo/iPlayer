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
}

// MARK: - 결과 타입

struct DetectedObject {
    let label: String
    let confidence: Float
    let boundingBox: CGRect
}

struct PoseJoint {
    let name: String
    let location: CGPoint   // Vision 정규화 좌표 (origin=bottom-left)
    let confidence: Float
}

struct PoseResult {
    let joints: [PoseJoint]
    let connections: [(Int, Int)]  // 관절 연결 인덱스 쌍
}

enum DetectionState {
    case idle
    case detecting
    case deferred
}

// MARK: - 통합 결과

enum DetectionResult {
    case objects([DetectedObject])
    case poses([PoseResult])
    case depthMap(CGImage)
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

    // 관절 연결 정의 (스켈레톤 라인)
    private static let poseConnections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.nose, .neck),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.neck, .root),
        (.root, .leftHip), (.root, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
    ]

    // MARK: - 모델 로드

    func loadModel(for newMode: DetectorMode) {
        mode = newMode

        // Pose는 모델 파일 불필요 (Apple Vision 내장)
        if newMode == .pose {
            isLoaded = true
            log("[ObjectDetector] Pose 모드 (Apple Vision 내장)")
            return
        }

        let modelName: String
        switch newMode {
        case .objectDetection: modelName = "YOLOv8n"
        case .depth: modelName = "MiDaSSmall"
        case .pose: return
        }

        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let modelURL = self.findModelURL(name: modelName) else {
                // 폴백: YOLOv3Tiny
                if newMode == .objectDetection, let fallback = self.findModelURL(name: "YOLOv3Tiny") {
                    self.loadCoreML(from: fallback, forDepth: false)
                    return
                }
                log("[ObjectDetector] \(modelName) 모델 파일 없음")
                return
            }
            self.loadCoreML(from: modelURL, forDepth: newMode == .depth)
        }
    }

    private func loadCoreML(from url: URL, forDepth: Bool) {
        do {
            let compiled: URL
            if url.pathExtension == "mlmodelc" {
                compiled = url
            } else {
                compiled = try MLModel.compileModel(at: url)
            }
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let mlModel = try MLModel(contentsOf: compiled, configuration: config)
            let vn = try VNCoreMLModel(for: mlModel)
            if forDepth {
                depthModel = vn
            } else {
                vnModel = vn
            }
            isLoaded = true
            log("[ObjectDetector] \(url.lastPathComponent) 로드 완료")
        } catch {
            log("[ObjectDetector] 모델 로드 실패: \(error)")
        }
    }

    // MARK: - 프레임 처리

    func processFrame(_ pixelBuffer: CVPixelBuffer, queueDepth: Int) {
        guard isEnabled, isLoaded, !isBusy else { return }

        if queueDepth >= queueDepthHealthy {
            // 매 프레임 시도
        } else if queueDepth >= queueDepthReduced {
            frameSkipCounter += 1
            guard frameSkipCounter >= 3 else { return }
            frameSkipCounter = 0
        } else {
            state = .deferred
            return
        }

        isBusy = true
        state = .detecting
        let gen = seekGeneration
        let currentMode = mode
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isBusy = false }
            guard gen == self.seekGeneration else { return }

            switch currentMode {
            case .objectDetection:
                self.runObjectDetection(pixelBuffer: pixelBuffer, gen: gen)
            case .pose:
                self.runPoseEstimation(pixelBuffer: pixelBuffer, gen: gen)
            case .depth:
                self.runDepthEstimation(pixelBuffer: pixelBuffer, gen: gen)
            }
            self.measureFPS()
        }
    }

    func processFrame(_ cgImage: CGImage, queueDepth: Int) {
        guard isEnabled, isLoaded, !isBusy else { return }

        if queueDepth >= queueDepthHealthy {
            // 매 프레임 시도
        } else if queueDepth >= queueDepthReduced {
            frameSkipCounter += 1
            guard frameSkipCounter >= 3 else { return }
            frameSkipCounter = 0
        } else {
            state = .deferred
            return
        }

        isBusy = true
        state = .detecting
        let gen = seekGeneration
        let currentMode = mode
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isBusy = false }
            guard gen == self.seekGeneration else { return }

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            switch currentMode {
            case .objectDetection:
                self.runObjectDetectionCG(handler: handler, gen: gen)
            case .pose:
                self.runPoseEstimationCG(handler: handler, gen: gen)
            case .depth:
                self.runDepthEstimationCG(handler: handler, gen: gen)
            }
            self.measureFPS()
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

    private func runObjectDetection(pixelBuffer: CVPixelBuffer, gen: Int) {
        guard let model = vnModel else { return }
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            self.handleObjectResults(req.results)
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func runObjectDetectionCG(handler: VNImageRequestHandler, gen: Int) {
        guard let model = vnModel else { return }
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            self.handleObjectResults(req.results)
        }
        request.imageCropAndScaleOption = .scaleFill
        try? handler.perform([request])
    }

    private func handleObjectResults(_ results: [Any]?) {
        guard let observations = results as? [VNRecognizedObjectObservation] else {
            setResult(.objects([]))
            return
        }
        let filtered = observations
            .filter { $0.confidence >= confidenceThreshold }
            .map { DetectedObject(label: $0.labels.first?.identifier ?? "?", confidence: $0.confidence, boundingBox: $0.boundingBox) }
        setResult(.objects(filtered))
    }

    // MARK: - 자세 추정 (Apple Vision 내장)

    private func runPoseEstimation(pixelBuffer: CVPixelBuffer, gen: Int) {
        let request = VNDetectHumanBodyPoseRequest { [weak self] req, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            self.handlePoseResults(req.results)
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func runPoseEstimationCG(handler: VNImageRequestHandler, gen: Int) {
        let request = VNDetectHumanBodyPoseRequest { [weak self] req, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            self.handlePoseResults(req.results)
        }
        try? handler.perform([request])
    }

    private func handlePoseResults(_ results: [Any]?) {
        guard let observations = results as? [VNHumanBodyPoseObservation] else {
            setResult(.poses([]))
            return
        }

        let jointNames: [VNHumanBodyPoseObservation.JointName] = [
            .nose, .neck,
            .leftShoulder, .rightShoulder,
            .leftElbow, .rightElbow,
            .leftWrist, .rightWrist,
            .root,
            .leftHip, .rightHip,
            .leftKnee, .rightKnee,
            .leftAnkle, .rightAnkle,
        ]

        var poses: [PoseResult] = []
        for obs in observations {
            var joints: [PoseJoint] = []
            for name in jointNames {
                if let pt = try? obs.recognizedPoint(name), pt.confidence > 0.1 {
                    joints.append(PoseJoint(name: name.rawValue.rawValue, location: pt.location, confidence: Float(pt.confidence)))
                } else {
                    joints.append(PoseJoint(name: name.rawValue.rawValue, location: .zero, confidence: 0))
                }
            }

            // 관절 인덱스 매핑으로 연결선 생성
            var connections: [(Int, Int)] = []
            for (from, to) in Self.poseConnections {
                if let fi = jointNames.firstIndex(of: from), let ti = jointNames.firstIndex(of: to) {
                    if joints[fi].confidence > 0.1 && joints[ti].confidence > 0.1 {
                        connections.append((fi, ti))
                    }
                }
            }
            poses.append(PoseResult(joints: joints, connections: connections))
        }
        setResult(.poses(poses))
    }

    // MARK: - 깊이 추정 (MiDaS)

    private func runDepthEstimation(pixelBuffer: CVPixelBuffer, gen: Int) {
        guard let model = depthModel else { return }
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            self.handleDepthResults(req.results)
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func runDepthEstimationCG(handler: VNImageRequestHandler, gen: Int) {
        guard let model = depthModel else { return }
        let request = VNCoreMLRequest(model: model) { [weak self] req, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            self.handleDepthResults(req.results)
        }
        request.imageCropAndScaleOption = .scaleFill
        try? handler.perform([request])
    }

    private func handleDepthResults(_ results: [Any]?) {
        guard let obs = results as? [VNCoreMLFeatureValueObservation],
              let first = obs.first,
              let multiArray = first.featureValue.multiArrayValue else {
            setResult(.empty)
            return
        }

        // MLMultiArray → 깊이 히트맵 CGImage 변환
        if let image = depthArrayToImage(multiArray) {
            setResult(.depthMap(image))
        } else {
            setResult(.empty)
        }
    }

    private func depthArrayToImage(_ array: MLMultiArray) -> CGImage? {
        let shape = array.shape.map { $0.intValue }
        guard shape.count >= 2 else { return nil }
        let h = shape[shape.count - 2]
        let w = shape[shape.count - 1]
        let count = w * h
        guard count > 0 else { return nil }

        // dataType에 무관하게 안전하게 Float 값 추출
        var values = [Float](repeating: 0, count: count)
        for i in 0..<count {
            values[i] = array[i].floatValue
        }

        // min-max 정규화
        var minVal: Float = .greatestFiniteMagnitude
        var maxVal: Float = -.greatestFiniteMagnitude
        for v in values {
            if v < minVal { minVal = v }
            if v > maxVal { maxVal = v }
        }
        let range = maxVal - minVal
        guard range > 0 else { return nil }

        // RGBA 히트맵 생성
        var pixelData = Data(count: count * 4)
        pixelData.withUnsafeMutableBytes { rawBuf in
            let ptr = rawBuf.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<count {
                let norm = (values[i] - minVal) / range
                let (r, g, b) = depthToColor(norm)
                ptr[i * 4] = r
                ptr[i * 4 + 1] = g
                ptr[i * 4 + 2] = b
                ptr[i * 4 + 3] = 160
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: pixelData as CFData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    private func depthToColor(_ value: Float) -> (UInt8, UInt8, UInt8) {
        // Turbo colormap (근사)
        let t = max(0, min(1, value))
        let r: Float
        let g: Float
        let b: Float
        if t < 0.25 {
            let s = t / 0.25
            r = 0; g = s; b = 1
        } else if t < 0.5 {
            let s = (t - 0.25) / 0.25
            r = 0; g = 1; b = 1 - s
        } else if t < 0.75 {
            let s = (t - 0.5) / 0.25
            r = s; g = 1; b = 0
        } else {
            let s = (t - 0.75) / 0.25
            r = 1; g = 1 - s; b = 0
        }
        return (UInt8(r * 255), UInt8(g * 255), UInt8(b * 255))
    }

    // MARK: - 공통

    private func setResult(_ result: DetectionResult) {
        resultsLock.lock()
        _latestResult = result
        resultsLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onDetectionUpdate?()
        }
    }

    private func measureFPS() {
        fpsCounter += 1
        let now = CACurrentMediaTime()
        if fpsTimerStart == 0 { fpsTimerStart = now }
        let elapsed = now - fpsTimerStart
        if elapsed >= 1.0 {
            detectionFPS = Double(fpsCounter) / elapsed
            fpsCounter = 0
            fpsTimerStart = now
        }
    }

    private func findModelURL(name: String) -> URL? {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let bundlePath = execURL.appendingPathComponent("iPlayer_iPlayer.bundle")
        if let bundle = Bundle(url: bundlePath) {
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
