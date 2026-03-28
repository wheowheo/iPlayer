import QuartzCore
import AppKit

final class DetectionOverlayLayer: CALayer {
    var detections: [DetectedObject] = [] {
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
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        let bounds = self.bounds
        guard !bounds.isEmpty else { return }

        for det in detections {
            // Vision bbox: origin=bottom-left, 정규화 0..1
            // CALayer도 bottom-left origin → 직접 매핑
            let rect = CGRect(
                x: det.boundingBox.origin.x * bounds.width,
                y: det.boundingBox.origin.y * bounds.height,
                width: det.boundingBox.width * bounds.width,
                height: det.boundingBox.height * bounds.height
            )

            let color = colorForLabel(det.label)

            // 바운딩 박스
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(2.0)
            ctx.stroke(rect)

            // 레이블 배경 + 텍스트
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
    }

    private func colorForLabel(_ label: String) -> NSColor {
        // 라벨별 고정 색상 (해시 기반)
        let hash = abs(label.hashValue)
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1.0)
    }
}
