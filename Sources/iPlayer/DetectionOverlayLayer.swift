import QuartzCore
import AppKit

final class DetectionOverlayLayer: CALayer {
    var detections: [DetectedObject] = [] {
        didSet { setNeedsDisplay() }
    }

    var detectionState: DetectionState = .idle {
        didSet { setNeedsDisplay() }
    }

    var detectionFPS: Double = 0 {
        didSet { setNeedsDisplay() }
    }

    override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? DetectionOverlayLayer {
            detections = other.detections
            detectionState = other.detectionState
            detectionFPS = other.detectionFPS
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        let bounds = self.bounds
        guard !bounds.isEmpty else { return }

        // 바운딩 박스
        for det in detections {
            let rect = CGRect(
                x: det.boundingBox.origin.x * bounds.width,
                y: det.boundingBox.origin.y * bounds.height,
                width: det.boundingBox.width * bounds.width,
                height: det.boundingBox.height * bounds.height
            )

            let color = colorForLabel(det.label)

            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2.0)
            ctx.stroke(rect)

            let label = "\(det.label) \(Int(det.confidence * 100))%"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                .foregroundColor: NSColor.white
            ]
            let attrStr = NSAttributedString(string: label, attributes: attrs)
            let textSize = attrStr.size()
            let labelRect = CGRect(
                x: rect.minX,
                y: rect.maxY,
                width: textSize.width + 8,
                height: textSize.height + 4
            )

            ctx.setFillColor(color.withAlphaComponent(0.75).cgColor)
            ctx.fill(labelRect)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            attrStr.draw(at: CGPoint(x: labelRect.minX + 4, y: labelRect.minY + 2))
            NSGraphicsContext.restoreGraphicsState()
        }

        // 상태 배지 (좌측 상단)
        drawStatusBadge(in: ctx, bounds: bounds)
    }

    private func drawStatusBadge(in ctx: CGContext, bounds: CGRect) {
        let text: String
        let badgeColor: NSColor

        switch detectionState {
        case .idle:
            return  // 비활성 시 배지 없음
        case .detecting:
            let fpsStr = detectionFPS > 0 ? String(format: " %.0f fps", detectionFPS) : ""
            text = "● 탐지 중\(fpsStr)"
            badgeColor = NSColor.systemGreen
        case .deferred:
            text = "◐ 탐지 대기"
            badgeColor = NSColor.systemOrange
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: badgeColor
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()

        let pad: CGFloat = 6
        let badgeRect = CGRect(
            x: pad,
            y: bounds.height - textSize.height - pad * 2,
            width: textSize.width + pad * 2,
            height: textSize.height + pad
        )

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        let path = CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
        ctx.addPath(path)
        ctx.fillPath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attrStr.draw(at: CGPoint(x: badgeRect.minX + pad, y: badgeRect.minY + pad * 0.5))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func colorForLabel(_ label: String) -> NSColor {
        let hash = abs(label.hashValue)
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1.0)
    }
}
