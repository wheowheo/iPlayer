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

final class ObjectDetector: @unchecked Sendable {
    private var vnModel: VNCoreMLModel?
    private let detectionQueue = DispatchQueue(label: "iPlayer.ObjectDetection", qos: .userInitiated)

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
    private var frameSkipCounter = 0
    var frameSkipInterval = 3
    var confidenceThreshold: Float = 0.5
    var isEnabled = false

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

    func processFrame(_ pixelBuffer: CVPixelBuffer) {
        guard isEnabled, isLoaded, !isBusy else { return }

        frameSkipCounter += 1
        guard frameSkipCounter >= frameSkipInterval else { return }
        frameSkipCounter = 0

        isBusy = true
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            self.runInference(on: pixelBuffer)
            self.isBusy = false
        }
    }

    func processFrame(_ cgImage: CGImage) {
        guard isEnabled, isLoaded, !isBusy else { return }

        frameSkipCounter += 1
        guard frameSkipCounter >= frameSkipInterval else { return }
        frameSkipCounter = 0

        isBusy = true
        detectionQueue.async { [weak self] in
            guard let self = self else { return }
            self.runInferenceCG(on: cgImage)
            self.isBusy = false
        }
    }

    func reset() {
        resultsLock.lock()
        _latestResults = []
        resultsLock.unlock()
        frameSkipCounter = 0
    }

    // MARK: - Private

    private func runInference(on pixelBuffer: CVPixelBuffer) {
        guard let vnModel = vnModel else { return }
        let request = VNCoreMLRequest(model: vnModel) { [weak self] request, _ in
            self?.handleResults(request.results)
        }
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    private func runInferenceCG(on cgImage: CGImage) {
        guard let vnModel = vnModel else { return }
        let request = VNCoreMLRequest(model: vnModel) { [weak self] request, _ in
            self?.handleResults(request.results)
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

    private func findModelURL() -> URL? {
        // 1. 번들 리소스에서 .mlmodelc 검색
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

        // 2. 실행 파일 옆 Resources/ 디렉토리
        let resourceDir = execURL.appendingPathComponent("Resources")
        for ext in ["mlmodelc", "mlmodel"] {
            let url = resourceDir.appendingPathComponent("YOLOv3Tiny.\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }

        // 3. 소스 트리의 Resources/ (개발 시)
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
