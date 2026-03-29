import Foundation
import AVFoundation
import CoreVideo

final class CameraController: NSObject, @unchecked Sendable {
    private var captureSession: AVCaptureSession?
    private let captureQueue = DispatchQueue(label: "iPlayer.CameraCapture", qos: .userInteractive)

    private(set) var isRunning = false
    private(set) var currentDeviceName: String = ""

    var onFrameReady: ((CVPixelBuffer, Int32, Int32) -> Void)?

    // MARK: - 카메라 목록

    static func availableCameras() -> [AVCaptureDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
    }

    // MARK: - 시작 / 정지

    func start(deviceID: String? = nil) -> Bool {
        stop()

        let device: AVCaptureDevice?
        if let id = deviceID {
            device = AVCaptureDevice(uniqueID: id)
        } else {
            device = AVCaptureDevice.default(for: .video)
        }

        guard let cam = device else {
            log("[Camera] 카메라 장치 없음")
            return false
        }

        let session = AVCaptureSession()
        session.sessionPreset = .high

        do {
            let input = try AVCaptureDeviceInput(device: cam)
            guard session.canAddInput(input) else {
                log("[Camera] 입력 추가 실패")
                return false
            }
            session.addInput(input)
        } catch {
            log("[Camera] 입력 생성 실패: \(error)")
            return false
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)

        guard session.canAddOutput(output) else {
            log("[Camera] 출력 추가 실패")
            return false
        }
        session.addOutput(output)

        // 전면 카메라 좌우 반전 (거울 모드)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }

        captureSession = session
        currentDeviceName = cam.localizedName
        session.startRunning()
        isRunning = true
        log("[Camera] 시작: \(cam.localizedName)")
        return true
    }

    func stop() {
        guard isRunning else { return }
        captureSession?.stopRunning()
        captureSession = nil
        isRunning = false
        currentDeviceName = ""
        log("[Camera] 정지")
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        onFrameReady?(pixelBuffer, w, h)
    }
}
