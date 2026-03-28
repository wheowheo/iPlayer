import Foundation
import CFFmpeg

struct StreamInfo {
    let index: Int32
    let codecID: AVCodecID
    let codecName: String
    let timeBase: AVRational
    let duration: Int64
    let mediaType: AVMediaType
}

struct VideoStreamInfo {
    let stream: StreamInfo
    let width: Int32
    let height: Int32
    let pixelFormat: AVPixelFormat
    let frameRate: AVRational
    let bitRate: Int64
    let rotation: Double  // 회전 각도 (0, 90, 180, 270)
    // rotation 적용 후 실제 표시 크기
    var displayWidth: Int32 {
        return (rotation == 90 || rotation == 270 || rotation == -90) ? height : width
    }
    var displayHeight: Int32 {
        return (rotation == 90 || rotation == 270 || rotation == -90) ? width : height
    }
}

struct AudioStreamInfo {
    let stream: StreamInfo
    let sampleRate: Int32
    let channels: Int32
    let channelLayout: AVChannelLayout
    let sampleFormat: AVSampleFormat
    let bitRate: Int64
}

final class Demuxer {
    private(set) var formatCtx: UnsafeMutablePointer<AVFormatContext>?
    private(set) var videoStreams: [VideoStreamInfo] = []
    private(set) var audioStreams: [AudioStreamInfo] = []
    private(set) var subtitleStreams: [StreamInfo] = []
    private(set) var duration: Double = 0

    var selectedVideoIndex: Int32 = -1
    var selectedAudioIndex: Int32 = -1
    var selectedSubtitleIndex: Int32 = -1

    func open(path: String) -> Bool {
        var ctx: UnsafeMutablePointer<AVFormatContext>? = nil
        guard avformat_open_input(&ctx, path, nil, nil) == 0, let ctx = ctx else {
            log("[Demuxer] 파일 열기 실패: \(path)")
            return false
        }
        self.formatCtx = ctx

        guard avformat_find_stream_info(ctx, nil) >= 0 else {
            log("[Demuxer] 스트림 정보 탐색 실패")
            close()
            return false
        }

        let durationTB = AVRational(num: 1, den: Int32(AV_TIME_BASE))
        if ctx.pointee.duration > 0 {
            duration = iplayer_pts_to_seconds(ctx.pointee.duration, durationTB)
        }

        for i in 0..<Int32(ctx.pointee.nb_streams) {
            let stream = ctx.pointee.streams[Int(i)]!
            let codecpar = stream.pointee.codecpar.pointee
            let codecDesc = avcodec_descriptor_get(codecpar.codec_id)
            let name = codecDesc != nil ? String(cString: codecDesc!.pointee.name) : "unknown"
            let info = StreamInfo(
                index: i,
                codecID: codecpar.codec_id,
                codecName: name,
                timeBase: stream.pointee.time_base,
                duration: stream.pointee.duration,
                mediaType: codecpar.codec_type
            )

            switch codecpar.codec_type {
            case AVMEDIA_TYPE_VIDEO:
                let rotation = iplayer_get_stream_rotation(stream)
                let vInfo = VideoStreamInfo(
                    stream: info,
                    width: codecpar.width,
                    height: codecpar.height,
                    pixelFormat: AVPixelFormat(rawValue: codecpar.format),
                    frameRate: av_guess_frame_rate(ctx, stream, nil),
                    bitRate: codecpar.bit_rate,
                    rotation: rotation
                )
                videoStreams.append(vInfo)
                if rotation != 0 {
                    log("[Demuxer] 비디오 회전: \(rotation)° (\(codecpar.width)x\(codecpar.height) → \(vInfo.displayWidth)x\(vInfo.displayHeight))")
                }
                if selectedVideoIndex < 0 { selectedVideoIndex = i }
            case AVMEDIA_TYPE_AUDIO:
                let aInfo = AudioStreamInfo(
                    stream: info,
                    sampleRate: codecpar.sample_rate,
                    channels: codecpar.ch_layout.nb_channels,
                    channelLayout: codecpar.ch_layout,
                    sampleFormat: AVSampleFormat(rawValue: codecpar.format),
                    bitRate: codecpar.bit_rate
                )
                audioStreams.append(aInfo)
                if selectedAudioIndex < 0 { selectedAudioIndex = i }
            case AVMEDIA_TYPE_SUBTITLE:
                subtitleStreams.append(info)
                if selectedSubtitleIndex < 0 { selectedSubtitleIndex = i }
            default:
                break
            }
        }

        log("[Demuxer] 열림: V=\(videoStreams.count) A=\(audioStreams.count) S=\(subtitleStreams.count) 길이=\(String(format: "%.1f", duration))초")
        return true
    }

    func readPacket() -> UnsafeMutablePointer<AVPacket>? {
        var pkt = av_packet_alloc()
        guard pkt != nil else { return nil }
        if av_read_frame(formatCtx, pkt) >= 0 {
            return pkt
        }
        av_packet_free(&pkt)
        return nil
    }

    func seek(to seconds: Double) {
        guard let ctx = formatCtx else { return }
        let ts = Int64(seconds * Double(AV_TIME_BASE))
        avformat_seek_file(ctx, -1, Int64.min, ts, Int64.max, 0)
    }

    func close() {
        if formatCtx != nil {
            avformat_close_input(&formatCtx)
        }
        videoStreams.removeAll()
        audioStreams.removeAll()
        subtitleStreams.removeAll()
        selectedVideoIndex = -1
        selectedAudioIndex = -1
        selectedSubtitleIndex = -1
        duration = 0
    }

    deinit {
        close()
    }
}
