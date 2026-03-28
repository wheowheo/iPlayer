import Foundation
import CFFmpeg
import CoreVideo
import VideoToolbox

final class VideoDecoder {
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var hwDeviceCtx: UnsafeMutablePointer<AVBufferRef>?
    private var swsCtx: UnsafeMutablePointer<SwsContext>?
    private(set) var isHardwareAccelerated = false
    private(set) var width: Int32 = 0
    private(set) var height: Int32 = 0
    private(set) var codecName: String = ""
    private var timeBase: AVRational = AVRational(num: 1, den: 1)

    func open(formatCtx: UnsafeMutablePointer<AVFormatContext>, streamIndex: Int32) -> Bool {
        let stream = formatCtx.pointee.streams[Int(streamIndex)]!
        let codecpar = stream.pointee.codecpar!
        timeBase = stream.pointee.time_base

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            log("[VideoDecoder] 코덱을 찾을 수 없음")
            return false
        }
        codecName = String(cString: codec.pointee.name)

        guard let ctx = avcodec_alloc_context3(codec) else {
            log("[VideoDecoder] 컨텍스트 할당 실패")
            return false
        }
        self.codecCtx = ctx

        avcodec_parameters_to_context(ctx, codecpar)
        width = ctx.pointee.width
        height = ctx.pointee.height

        if tryHardwareAcceleration(ctx: ctx, codec: codec) {
            isHardwareAccelerated = true
            ctx.pointee.extra_hw_frames = 8  // I-프레임 버스트 시 surface 경합 감소
            log("[VideoDecoder] HW 가속 활성화 (VideoToolbox) - \(codecName)")
        } else {
            log("[VideoDecoder] SW 디코딩으로 폴백 - \(codecName)")
        }

        ctx.pointee.thread_count = 0
        if avcodec_open2(ctx, codec, nil) < 0 {
            log("[VideoDecoder] 코덱 열기 실패")
            close()
            return false
        }

        return true
    }

    private func tryHardwareAcceleration(ctx: UnsafeMutablePointer<AVCodecContext>, codec: UnsafePointer<AVCodec>) -> Bool {
        var idx: Int32 = 0
        while true {
            guard let config = avcodec_get_hw_config(codec, idx) else { break }
            if config.pointee.methods & Int32(AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX) != 0
                && config.pointee.device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX {

                var deviceCtx: UnsafeMutablePointer<AVBufferRef>? = nil
                if av_hwdevice_ctx_create(&deviceCtx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, nil, nil, 0) >= 0 {
                    ctx.pointee.hw_device_ctx = av_buffer_ref(deviceCtx)
                    self.hwDeviceCtx = deviceCtx
                    return true
                }
            }
            idx += 1
        }
        return false
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [VideoFrame] {
        guard let ctx = codecCtx else { return [] }
        var frames: [VideoFrame] = []

        guard avcodec_send_packet(ctx, packet) >= 0 else { return [] }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard frame != nil else { return [] }
        defer { av_frame_free(&frame) }

        while avcodec_receive_frame(ctx, frame) >= 0 {
            guard let f = frame else { break }
            let pts = iplayer_pts_to_seconds(f.pointee.best_effort_timestamp, timeBase)

            if isHardwareAccelerated && f.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
                if let pixelBuffer = f.pointee.data.3 {
                    let cvBuf = Unmanaged<CVPixelBuffer>.fromOpaque(pixelBuffer).retain().takeRetainedValue()
                    frames.append(VideoFrame(pixelBuffer: cvBuf, pts: pts, width: width, height: height))
                }
            } else {
                if let image = convertFrameToCGImage(f) {
                    frames.append(VideoFrame(cgImage: image, pts: pts, width: width, height: height))
                }
            }
        }

        return frames
    }

    func flush() {
        guard let ctx = codecCtx else { return }
        avcodec_flush_buffers(ctx)
    }

    /// EOF 시 디코더에 남은 프레임을 모두 꺼냄
    func drain() -> [VideoFrame] {
        guard let ctx = codecCtx else { return [] }
        var frames: [VideoFrame] = []

        // null 패킷 전송 → 디코더 드레인 모드
        avcodec_send_packet(ctx, nil)

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard frame != nil else { return [] }
        defer { av_frame_free(&frame) }

        while avcodec_receive_frame(ctx, frame) >= 0 {
            guard let f = frame else { break }
            let pts = iplayer_pts_to_seconds(f.pointee.best_effort_timestamp, timeBase)

            if isHardwareAccelerated && f.pointee.format == AV_PIX_FMT_VIDEOTOOLBOX.rawValue {
                if let pixelBuffer = f.pointee.data.3 {
                    let cvBuf = Unmanaged<CVPixelBuffer>.fromOpaque(pixelBuffer).retain().takeRetainedValue()
                    frames.append(VideoFrame(pixelBuffer: cvBuf, pts: pts, width: width, height: height))
                }
            } else {
                if let image = convertFrameToCGImage(f) {
                    frames.append(VideoFrame(cgImage: image, pts: pts, width: width, height: height))
                }
            }
        }

        return frames
    }

    private func convertFrameToCGImage(_ frame: UnsafeMutablePointer<AVFrame>) -> CGImage? {
        let srcFormat = AVPixelFormat(rawValue: frame.pointee.format)
        let dstFormat = AV_PIX_FMT_BGRA
        let w = frame.pointee.width
        let h = frame.pointee.height

        if swsCtx == nil {
            swsCtx = sws_getContext(
                w, h, srcFormat,
                w, h, dstFormat,
                Int32(SWS_BILINEAR.rawValue), nil, nil, nil
            )
        }
        guard let swsCtx = swsCtx else { return nil }

        let linesize = w * 4
        let bufSize = Int(linesize * h)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }

        var dstSlice: UnsafeMutablePointer<UInt8>? = buffer
        var dstStride = linesize

        let srcData0: UnsafePointer<UInt8>? = UnsafePointer(frame.pointee.data.0)
        let srcData1: UnsafePointer<UInt8>? = UnsafePointer(frame.pointee.data.1)
        let srcData2: UnsafePointer<UInt8>? = UnsafePointer(frame.pointee.data.2)
        let srcData3: UnsafePointer<UInt8>? = UnsafePointer(frame.pointee.data.3)
        var srcSlices = [srcData0, srcData1, srcData2, srcData3]
        var srcStrides = [frame.pointee.linesize.0, frame.pointee.linesize.1,
                          frame.pointee.linesize.2, frame.pointee.linesize.3]

        srcSlices.withUnsafeMutableBufferPointer { srcBuf in
            srcStrides.withUnsafeMutableBufferPointer { strideBuf in
                withUnsafeMutablePointer(to: &dstSlice) { dstPtr in
                    withUnsafeMutablePointer(to: &dstStride) { dstStridePtr in
                        _ = sws_scale(swsCtx,
                                      srcBuf.baseAddress, strideBuf.baseAddress,
                                      0, h,
                                      dstPtr, dstStridePtr)
                    }
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: buffer,
            width: Int(w),
            height: Int(h),
            bitsPerComponent: 8,
            bytesPerRow: Int(linesize),
            space: colorSpace,
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        return context.makeImage()
    }

    func close() {
        if codecCtx != nil {
            avcodec_free_context(&self.codecCtx)
        }
        if hwDeviceCtx != nil {
            av_buffer_unref(&self.hwDeviceCtx)
        }
        if let sws = swsCtx {
            sws_freeContext(sws)
            swsCtx = nil
        }
    }

    deinit {
        close()
    }
}

struct VideoFrame: @unchecked Sendable {
    var pixelBuffer: CVPixelBuffer?
    var cgImage: CGImage?
    let pts: Double
    let width: Int32
    let height: Int32

    init(pixelBuffer: CVPixelBuffer, pts: Double, width: Int32, height: Int32) {
        self.pixelBuffer = pixelBuffer
        self.cgImage = nil
        self.pts = pts
        self.width = width
        self.height = height
    }

    init(cgImage: CGImage, pts: Double, width: Int32, height: Int32) {
        self.pixelBuffer = nil
        self.cgImage = cgImage
        self.pts = pts
        self.width = width
        self.height = height
    }
}
