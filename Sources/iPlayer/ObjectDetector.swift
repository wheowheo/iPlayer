import Foundation
import Vision
import CoreML
import CoreVideo
import AppKit

struct DetectedObject {
    let label: String
    let confidence: Float
    let boundingBox: CGRect  // Vision 정규화 좌표 (origin=bottom-left, 0..1)
}

enum DetectionState {
    case idle       // 비활성
    case detecting  // 추론 진행 중
    case deferred   // 자원 부족으로 보류
}

final class ObjectDetector: @unchecked Sendable {
    private var vnModel: VNCoreMLModel?
    // 비디오보다 낮은 우선순위 — 자원 경합 시 비디오가 우선
    private let detectionQueue = DispatchQueue(label: "iPlayer.ObjectDetection", qos: .utility)

    private let resultsLock = NSLock()
    private var _latestResults: [DetectedObject] = []
    var latestResults: [DetectedObject] {
        resultsLock.lock()
        let r = _latestResults
        resultsLock.unlock()
        return r
    }

    private(set) var isLoaded = false
    private var isBusy = false
    private var seekGeneration: Int = 0
    private var frameSkipCounter = 0
    var confidenceThreshold: Float = 0.5
    var isEnabled = false

    // 적응적 프레임 스킵 임계값
    private let queueDepthHealthy = 30    // 이 이상이면 정상 탐지
    private let queueDepthReduced = 15    // 이 이상이면 감소 모드
    // 이하이면 탐지 보류

    // 탐지 상태
    private(set) var state: DetectionState = .idle
    private(set) var detectionFPS: Double = 0
    private var fpsCounter = 0
    private var fpsTimerStart: Double = 0

    var onDetectionUpdate: (() -> Void)?

    func loadModel() {
        guard !isLoaded else { return }
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let modelURL = self.findModelURL() else {
                log("[ObjectDetector] 모델 파일 없음")
                return
            }
            do {
                let compiled: URL
                if modelURL.pathExtension == "mlmodelc" {
                    compiled = modelURL
                } else {
                    compiled = try MLModel.compileModel(at: modelURL)
                }
                let config = MLModelConfiguration()
                config.computeUnits = .all
                let mlModel = try MLModel(contentsOf: compiled, configuration: config)
                self.vnModel = try VNCoreMLModel(for: mlModel)
                self.isLoaded = true
                log("[ObjectDetector] 모델 로드 완료")
            } catch {
                log("[ObjectDetector] 모델 로드 실패: \(error)")
            }
        }
    }

    func loadModel(at url: URL) {
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
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
                self.vnModel = try VNCoreMLModel(for: mlModel)
                self.isLoaded = true
                log("[ObjectDetector] 외부 모델 로드 완료: \(url.lastPathComponent)")
            } catch {
                log("[ObjectDetector] 외부 모델 로드 실패: \(error)")
            }
        }
    }

    /// 프레임 큐 깊이를 받아 자원 경합 시 탐지를 보류
    func processFrame(_ pixelBuffer: CVPixelBuffer, queueDepth: Int) {
        guard isEnabled, isLoaded, !isBusy else { return }

        // 프레임 큐 깊이에 따른 적응적 스케줄링
        let skipInterval: Int
        if queueDepth >= queueDepthHealthy {
            skipInterval = 3   // 정상: 3프레임마다 탐지
        } else if queueDepth >= queueDepthReduced {
            skipInterval = 8   // 감소: 8프레임마다 탐지
        } else {
            // 큐 부족 → 탐지 보류, 비디오 우선
            state = .deferred
            return
        }

        frameSkipCounter += 1
        guard frameSkipCounter >= skipInterval else { return }
        frameSkipCounter = 0

        guard let safeCopy = copyPixelBuffer(pixelBuffer) else { return }

        isBusy = true
        state = .detecting
        let gen = seekGeneration
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isBusy = false }
            guard gen == self.seekGeneration else { return }
            self.runInference(on: safeCopy)
            self.measureFPS()
        }
    }

    func processFrame(_ cgImage: CGImage, queueDepth: Int) {
        guard isEnabled, isLoaded, !isBusy else { return }

        let skipInterval: Int
        if queueDepth >= queueDepthHealthy {
            skipInterval = 3
        } else if queueDepth >= queueDepthReduced {
            skipInterval = 8
        } else {
            state = .deferred
            return
        }

        frameSkipCounter += 1
        guard frameSkipCounter >= skipInterval else { return }
        frameSkipCounter = 0

        isBusy = true
        state = .detecting
        let gen = seekGeneration
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.isBusy = false }
            guard gen == self.seekGeneration else { return }
            self.runInferenceCG(on: cgImage)
            self.measureFPS()
        }
    }

    /// Seek 발생 시 호출 — 결과 클리어 + 진행 중 추론 무효화
    func reset() {
        seekGeneration += 1
        isBusy = false
        frameSkipCounter = 0
        state = .idle
        detectionFPS = 0
        fpsCounter = 0
        resultsLock.lock()
        _latestResults = []
        resultsLock.unlock()
    }

    // MARK: - Private

    private func runInference(on pixelBuffer: CVPixelBuffer) {
        guard let vnModel = vnModel else { return }
        let gen = seekGeneration
        let request = VNCoreMLRequest(model: vnModel) { [weak self] request, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            self.handleResults(request.results)
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func runInferenceCG(on cgImage: CGImage) {
        guard let vnModel = vnModel else { return }
        let gen = seekGeneration
        let request = VNCoreMLRequest(model: vnModel) { [weak self] request, _ in
            guard let self = self, gen == self.seekGeneration else { return }
            self.handleResults(request.results)
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
    }

    private func handleResults(_ results: [Any]?) {
        guard let observations = results as? [VNRecognizedObjectObservation] else {
            resultsLock.lock()
            _latestResults = []
            resultsLock.unlock()
            return
        }
        let filtered = observations
            .filter { $0.confidence >= confidenceThreshold }
            .map { obs in
                DetectedObject(
                    label: obs.labels.first?.identifier ?? "unknown",
                    confidence: obs.confidence,
                    boundingBox: obs.boundingBox
                )
            }
        resultsLock.lock()
        _latestResults = filtered
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

    /// CVPixelBuffer를 독립된 복사본으로 생성
    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(source)
        let height = CVPixelBufferGetHeight(source)
        let pixelFormat = CVPixelBufferGetPixelFormatType(source)

        var copy: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, nil, &copy)
        guard status == kCVReturnSuccess, let dst = copy else { return nil }

        CVPixelBufferLockBaseAddress(source, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(source, .readOnly)
            CVPixelBufferUnlockBaseAddress(dst, [])
        }

        let planeCount = CVPixelBufferGetPlaneCount(source)
        if planeCount > 0 {
            for plane in 0..<planeCount {
                guard let srcAddr = CVPixelBufferGetBaseAddressOfPlane(source, plane),
                      let dstAddr = CVPixelBufferGetBaseAddressOfPlane(dst, plane) else { continue }
                let srcStride = CVPixelBufferGetBytesPerRowOfPlane(source, plane)
                let dstStride = CVPixelBufferGetBytesPerRowOfPlane(dst, plane)
                let h = CVPixelBufferGetHeightOfPlane(source, plane)
                let rowBytes = min(srcStride, dstStride)
                for row in 0..<h {
                    memcpy(dstAddr + row * dstStride, srcAddr + row * srcStride, rowBytes)
                }
            }
        } else {
            guard let srcAddr = CVPixelBufferGetBaseAddress(source),
                  let dstAddr = CVPixelBufferGetBaseAddress(dst) else { return nil }
            let srcStride = CVPixelBufferGetBytesPerRow(source)
            let dstStride = CVPixelBufferGetBytesPerRow(dst)
            let rowBytes = min(srcStride, dstStride)
            for row in 0..<height {
                memcpy(dstAddr + row * dstStride, srcAddr + row * srcStride, rowBytes)
            }
        }

        return dst
    }

    private func findModelURL() -> URL? {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let bundleName = "iPlayer_iPlayer.bundle"
        let bundlePath = execURL.appendingPathComponent(bundleName)
        if let bundle = Bundle(url: bundlePath) {
            if let url = bundle.url(forResource: "YOLOv3Tiny", withExtension: "mlmodelc") {
                return url
            }
            if let url = bundle.url(forResource: "YOLOv3Tiny", withExtension: "mlmodel") {
                return url
            }
        }

        let resourceDir = execURL.appendingPathComponent("Resources")
        for ext in ["mlmodelc", "mlmodel"] {
            let url = resourceDir.appendingPathComponent("YOLOv3Tiny.\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        let srcResource = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        for ext in ["mlmodelc", "mlmodel"] {
            let url = srcResource.appendingPathComponent("YOLOv3Tiny.\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        return nil
    }
}
