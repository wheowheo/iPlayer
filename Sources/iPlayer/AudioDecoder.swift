import Foundation
import CFFmpeg

struct AudioBuffer {
    let data: Data
    let pts: Double
    let sampleCount: Int
    let sampleRate: Int32
    let channels: Int32
}

final class AudioDecoder {
    private var codecCtx: UnsafeMutablePointer<AVCodecContext>?
    private var swrCtx: OpaquePointer?
    private(set) var sampleRate: Int32 = 44100
    private(set) var channels: Int32 = 2
    private(set) var codecName: String = ""
    private var timeBase: AVRational = AVRational(num: 1, den: 1)

    let outputSampleRate: Int32 = 48000
    let outputChannels: Int32 = 2
    let outputSampleFormat = AV_SAMPLE_FMT_FLT

    func open(formatCtx: UnsafeMutablePointer<AVFormatContext>, streamIndex: Int32) -> Bool {
        let stream = formatCtx.pointee.streams[Int(streamIndex)]!
        let codecpar = stream.pointee.codecpar!
        timeBase = stream.pointee.time_base

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            print("[AudioDecoder] 코덱을 찾을 수 없음")
            return false
        }
        codecName = String(cString: codec.pointee.name)

        guard let ctx = avcodec_alloc_context3(codec) else {
            print("[AudioDecoder] 컨텍스트 할당 실패")
            return false
        }
        self.codecCtx = ctx

        avcodec_parameters_to_context(ctx, codecpar)
        sampleRate = ctx.pointee.sample_rate
        channels = ctx.pointee.ch_layout.nb_channels

        if avcodec_open2(ctx, codec, nil) < 0 {
            print("[AudioDecoder] 코덱 열기 실패")
            close()
            return false
        }

        setupResampler(ctx: ctx)
        print("[AudioDecoder] 열림: \(codecName) \(sampleRate)Hz \(channels)ch")
        return true
    }

    private func setupResampler(ctx: UnsafeMutablePointer<AVCodecContext>) {
        var swr: OpaquePointer? = nil
        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, outputChannels)
        _ = swr_alloc_set_opts2(
            &swr,
            &outLayout,
            outputSampleFormat,
            outputSampleRate,
            &ctx.pointee.ch_layout,
            ctx.pointee.sample_fmt,
            ctx.pointee.sample_rate,
            0, nil
        )
        if let swr = swr {
            swr_init(swr)
            self.swrCtx = swr
        }
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [AudioBuffer] {
        guard let ctx = codecCtx else { return [] }
        var buffers: [AudioBuffer] = []

        guard avcodec_send_packet(ctx, packet) >= 0 else { return [] }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        guard frame != nil else { return [] }
        defer { av_frame_free(&frame) }

        while avcodec_receive_frame(ctx, frame) >= 0 {
            guard let f = frame else { break }
            let pts = iplayer_pts_to_seconds(f.pointee.best_effort_timestamp, timeBase)

            if let swr = swrCtx {
                let outSamples = swr_get_out_samples(swr, f.pointee.nb_samples)
                let bytesPerSample = Int(iplayer_av_get_bytes_per_sample(outputSampleFormat))
                let bufferSize = Int(outSamples) * Int(outputChannels) * bytesPerSample

                var outputData = Data(count: bufferSize)
                let convertedSamples = outputData.withUnsafeMutableBytes { rawBuf -> Int32 in
                    guard let baseAddr = rawBuf.baseAddress else { return 0 }
                    var outPtr: UnsafeMutablePointer<UInt8>? = baseAddr.assumingMemoryBound(to: UInt8.self)
                    let srcData = UnsafePointer<UnsafePointer<UInt8>?>(OpaquePointer(f.pointee.extended_data))
                    return withUnsafeMutablePointer(to: &outPtr) { outPtrPtr in
                        swr_convert(swr, outPtrPtr, outSamples,
                                    srcData, f.pointee.nb_samples)
                    }
                }

                if convertedSamples > 0 {
                    let actualSize = Int(convertedSamples) * Int(outputChannels) * bytesPerSample
                    outputData = outputData.prefix(actualSize)
                    buffers.append(AudioBuffer(
                        data: outputData,
                        pts: pts,
                        sampleCount: Int(convertedSamples),
                        sampleRate: outputSampleRate,
                        channels: outputChannels
                    ))
                }
            }
        }

        return buffers
    }

    func flush() {
        guard let ctx = codecCtx else { return }
        avcodec_flush_buffers(ctx)
    }

    func close() {
        if swrCtx != nil {
            swr_free(&swrCtx)
        }
        if codecCtx != nil {
            avcodec_free_context(&codecCtx)
        }
    }

    deinit {
        close()
    }
}
