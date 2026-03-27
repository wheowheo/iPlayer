import Foundation

struct SubtitleEntry {
    let startTime: Double  // seconds
    let endTime: Double    // seconds
    let text: String
}

enum SubtitleParser {
    // MARK: - SRT 파서
    static func parseSRT(content: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        let blocks = content.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n")
            guard lines.count >= 3 else { continue }

            // 두 번째 줄: 타임코드
            let timeLine = lines[1]
            guard let (start, end) = parseSRTTimecode(timeLine) else { continue }

            // 나머지: 텍스트
            let text = lines[2...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            entries.append(SubtitleEntry(startTime: start, endTime: end, text: text))
        }

        return entries.sorted { $0.startTime < $1.startTime }
    }

    private static func parseSRTTimecode(_ line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: " --> ")
        guard parts.count == 2 else { return nil }
        guard let start = srtTimeToSeconds(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = srtTimeToSeconds(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (start, end)
    }

    private static func srtTimeToSeconds(_ time: String) -> Double? {
        // 00:01:23,456 또는 00:01:23.456
        let normalized = time.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]),
              let m = Double(parts[1]),
              let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    // MARK: - SMI 파서
    static func parseSMI(content: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []

        // <SYNC Start=밀리초> 패턴 찾기
        let pattern = #"<SYNC\s+Start\s*=\s*(\d+)\s*>(.*?)(?=<SYNC|</BODY>|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))

        struct RawSync {
            let time: Double
            let text: String
        }
        var syncs: [RawSync] = []

        for match in matches {
            guard match.numberOfRanges >= 3 else { continue }
            let timeStr = nsContent.substring(with: match.range(at: 1))
            let rawText = nsContent.substring(with: match.range(at: 2))

            guard let ms = Double(timeStr) else { continue }
            let time = ms / 1000.0

            // HTML 태그 제거
            let text = rawText
                .replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
                .replacingOccurrences(of: "<BR>", with: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&nbsp;", with: " ")

            syncs.append(RawSync(time: time, text: text))
        }

        // 연속된 SYNC 쌍을 자막 엔트리로 변환
        for i in 0..<syncs.count {
            let current = syncs[i]
            guard !current.text.isEmpty && current.text != " " else { continue }

            let endTime: Double
            if i + 1 < syncs.count {
                endTime = syncs[i + 1].time
            } else {
                endTime = current.time + 5.0
            }

            entries.append(SubtitleEntry(startTime: current.time, endTime: endTime, text: current.text))
        }

        return entries.sorted { $0.startTime < $1.startTime }
    }

    // MARK: - 자동 감지
    static func parse(fileURL: URL) -> [SubtitleEntry] {
        // 인코딩 자동 감지
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let content = detectEncodingAndDecode(data: data)

        let ext = fileURL.pathExtension.lowercased()
        switch ext {
        case "srt":
            return parseSRT(content: content)
        case "smi", "smil":
            return parseSMI(content: content)
        default:
            // 내용으로 추측
            if content.contains("<SAMI>") || content.contains("<sami>") {
                return parseSMI(content: content)
            }
            return parseSRT(content: content)
        }
    }

    private static func detectEncodingAndDecode(data: Data) -> String {
        // UTF-8 BOM 확인
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8) ?? ""
        }
        // UTF-16 LE BOM
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data, encoding: .utf16LittleEndian) ?? ""
        }
        // UTF-16 BE BOM
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        }
        // UTF-8 시도
        if let str = String(data: data, encoding: .utf8) {
            return str
        }
        // EUC-KR (한국어 자막용)
        let cfEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)
        )
        if let str = String(data: data, encoding: String.Encoding(rawValue: cfEncoding)) {
            return str
        }
        // 최후 수단
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
