import AppKit

final class AudioMeterView: NSView {
    private var levelL: Float = 0
    private var levelR: Float = 0
    private var peakL: Float = 0
    private var peakR: Float = 0
    private var pcmData: [Float] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
        layer?.cornerRadius = 4
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(levelL: Float, levelR: Float, peakL: Float, peakR: Float, pcm: [Float]) {
        self.levelL = levelL
        self.levelR = levelR
        self.peakL = peakL
        self.peakR = peakR
        self.pcmData = pcm
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let pad: CGFloat = 10
        let innerW = bounds.width - pad * 2

        // --- 레벨 미터 ---
        let meterH: CGFloat = 14
        let meterTopY = bounds.height - pad - meterH
        let labelW: CGFloat = 14

        drawLabel("L", at: NSPoint(x: pad, y: meterTopY + 1))
        drawLevelBar(level: levelL, peak: peakL,
                     rect: NSRect(x: pad + labelW, y: meterTopY, width: innerW - labelW, height: meterH))

        let meterBotY = meterTopY - meterH - 6
        drawLabel("R", at: NSPoint(x: pad, y: meterBotY + 1))
        drawLevelBar(level: levelR, peak: peakR,
                     rect: NSRect(x: pad + labelW, y: meterBotY, width: innerW - labelW, height: meterH))

        // --- PCM 파형 ---
        let waveTop = meterBotY - 12
        let waveH = (waveTop - pad) / 2 - 4
        guard waveH > 8 else { return }

        let waveRectL = NSRect(x: pad, y: waveTop - waveH, width: innerW, height: waveH)
        let waveRectR = NSRect(x: pad, y: waveTop - waveH * 2 - 8, width: innerW, height: waveH)

        drawSmallLabel("PCM L", at: NSPoint(x: pad + 2, y: waveRectL.maxY - 12))
        drawWaveform(channel: 0, rect: waveRectL, color: .systemGreen)

        drawSmallLabel("PCM R", at: NSPoint(x: pad + 2, y: waveRectR.maxY - 12))
        drawWaveform(channel: 1, rect: waveRectR, color: .systemCyan)
    }

    // MARK: - 레벨 바

    private func drawLevelBar(level: Float, peak: Float, rect: NSRect) {
        // 배경
        NSColor(white: 0.15, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

        let lvl = CGFloat(min(max(level, 0), 1))
        let levelWidth = rect.width * lvl
        guard levelWidth > 0 else { return }

        // 구간별 색상: 0~50% green, 50~85% yellow, 85~100% red
        let greenEnd = rect.width * 0.5
        let yellowEnd = rect.width * 0.85

        let greenW = min(levelWidth, greenEnd)
        NSColor.systemGreen.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX, y: rect.minY, width: greenW, height: rect.height),
                     xRadius: 2, yRadius: 2).fill()

        if levelWidth > greenEnd {
            let yellowW = min(levelWidth - greenEnd, yellowEnd - greenEnd)
            NSColor.systemYellow.setFill()
            NSRect(x: rect.minX + greenEnd, y: rect.minY, width: yellowW, height: rect.height).fill()
        }

        if levelWidth > yellowEnd {
            let redW = levelWidth - yellowEnd
            NSColor.systemRed.setFill()
            NSRect(x: rect.minX + yellowEnd, y: rect.minY, width: redW, height: rect.height).fill()
        }

        // 피크 인디케이터
        let peakVal = CGFloat(min(max(peak, 0), 1))
        if peakVal > 0.01 {
            let peakX = rect.minX + rect.width * peakVal
            NSColor.white.setFill()
            NSRect(x: peakX - 1, y: rect.minY, width: 2, height: rect.height).fill()
        }

        // dB 표시
        let db = level > 0.0001 ? 20 * log10(level) : -60
        let dbStr = String(format: "%+.0f dB", max(db, -60))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.white
        ]
        let strSize = dbStr.size(withAttributes: attrs)
        dbStr.draw(at: NSPoint(x: rect.maxX - strSize.width - 2, y: rect.minY + 1), withAttributes: attrs)
    }

    // MARK: - PCM 파형

    private func drawWaveform(channel: Int, rect: NSRect, color: NSColor) {
        // 배경
        NSColor(white: 0.08, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

        // 중심선
        let centerY = rect.midY
        NSColor(white: 0.25, alpha: 1).setStroke()
        let centerLine = NSBezierPath()
        centerLine.move(to: NSPoint(x: rect.minX, y: centerY))
        centerLine.line(to: NSPoint(x: rect.maxX, y: centerY))
        centerLine.lineWidth = 0.5
        centerLine.stroke()

        guard !pcmData.isEmpty else { return }
        let channels = 2
        let frameCount = pcmData.count / channels
        guard frameCount > 0 && channel < channels else { return }

        color.withAlphaComponent(0.8).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1

        let pointCount = Int(rect.width)
        let samplesPerPoint = max(1, frameCount / pointCount)
        let halfH = rect.height / 2 - 2

        for i in 0..<min(pointCount, frameCount) {
            let sampleIdx = i * samplesPerPoint
            let idx = sampleIdx * channels + channel
            guard idx < pcmData.count else { break }

            let sample = CGFloat(pcmData[idx])
            let x = rect.minX + CGFloat(i) / CGFloat(pointCount) * rect.width
            let y = centerY + sample * halfH

            if i == 0 { path.move(to: NSPoint(x: x, y: y)) }
            else { path.line(to: NSPoint(x: x, y: y)) }
        }
        path.stroke()
    }

    // MARK: - 유틸

    private func drawLabel(_ text: String, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        text.draw(at: point, withAttributes: attrs)
    }

    private func drawSmallLabel(_ text: String, at point: NSPoint) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor(white: 0.5, alpha: 1)
        ]
        text.draw(at: point, withAttributes: attrs)
    }
}
