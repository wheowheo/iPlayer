import QuartzCore
import AppKit

final class DetectionOverlayLayer: CALayer {
    var result: DetectionResult = .empty {
        didSet { setNeedsDisplay() }
    }

    var detectionState: DetectionState = .idle {
        didSet { setNeedsDisplay() }
    }

    var detectionFPS: Double = 0 {
        didSet { setNeedsDisplay() }
    }

    var activeMode: DetectorMode = .objectDetection {
        didSet { setNeedsDisplay() }
    }

    var hideStatusBadge = false {
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
        if let o = layer as? DetectionOverlayLayer {
            result = o.result
            detectionState = o.detectionState
            detectionFPS = o.detectionFPS
            activeMode = o.activeMode
            hideStatusBadge = o.hideStatusBadge
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        let bounds = self.bounds
        guard !bounds.isEmpty else { return }

        switch result {
        case .objects(let objects):
            drawObjects(objects, in: ctx, bounds: bounds)
        case .poses(let poses):
            drawPoses(poses, in: ctx, bounds: bounds)
        case .depthMap(let image):
            drawDepth(image, in: ctx, bounds: bounds)
        case .empty:
            break
        }

        if !hideStatusBadge {
            drawStatusBadge(in: ctx, bounds: bounds)
        }
    }

    // MARK: - 객체 탐지 (바운딩 박스)

    private func drawObjects(_ objects: [DetectedObject], in ctx: CGContext, bounds: CGRect) {
        for det in objects {
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
            let labelRect = CGRect(x: rect.minX, y: rect.maxY, width: textSize.width + 8, height: textSize.height + 4)

            ctx.setFillColor(color.withAlphaComponent(0.75).cgColor)
            ctx.fill(labelRect)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            attrStr.draw(at: CGPoint(x: labelRect.minX + 4, y: labelRect.minY + 2))
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    // MARK: - 자세 추정 (스켈레톤)

    private func drawPoses(_ poses: [PoseResult], in ctx: CGContext, bounds: CGRect) {
        for pose in poses {
            // 연결선
            ctx.setStrokeColor(NSColor.systemGreen.cgColor)
            ctx.setLineWidth(3.0)
            ctx.setLineCap(.round)
            for (fi, ti) in pose.connections {
                let from = pose.joints[fi]
                let to = pose.joints[ti]
                let p1 = CGPoint(x: from.location.x * bounds.width, y: from.location.y * bounds.height)
                let p2 = CGPoint(x: to.location.x * bounds.width, y: to.location.y * bounds.height)
                ctx.move(to: p1)
                ctx.addLine(to: p2)
            }
            ctx.strokePath()

            // 관절 포인트
            for joint in pose.joints where joint.confidence > 0.1 {
                let pt = CGPoint(x: joint.location.x * bounds.width, y: joint.location.y * bounds.height)
                let r: CGFloat = 5
                let circle = CGRect(x: pt.x - r, y: pt.y - r, width: r * 2, height: r * 2)

                ctx.setFillColor(NSColor.systemYellow.cgColor)
                ctx.fillEllipse(in: circle)
                ctx.setStrokeColor(NSColor.white.cgColor)
                ctx.setLineWidth(1.5)
                ctx.strokeEllipse(in: circle)
            }
        }
    }

    // MARK: - 깊이 추정 (히트맵)

    private func drawDepth(_ image: CGImage, in ctx: CGContext, bounds: CGRect) {
        ctx.draw(image, in: bounds)
    }

    // MARK: - 상태 배지

    private func drawStatusBadge(in ctx: CGContext, bounds: CGRect) {
        let text: String
        let badgeColor: NSColor

        switch detectionState {
        case .idle:
            return
        case .detecting:
            let fpsStr = detectionFPS > 0 ? String(format: " %.0f fps", detectionFPS) : ""
            text = "● \(activeMode.rawValue)\(fpsStr)"
            badgeColor = NSColor.systemGreen
        case .deferred:
            text = "◐ 탐지 대기"
            badgeColor = NSColor.systemOrange
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: badgeColor]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let textSize = attrStr.size()

        let pad: CGFloat = 6
        let badgeRect = CGRect(x: pad, y: bounds.height - textSize.height - pad * 2,
                               width: textSize.width + pad * 2, height: textSize.height + pad)

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(CGPath(roundedRect: badgeRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attrStr.draw(at: CGPoint(x: badgeRect.minX + pad, y: badgeRect.minY + pad * 0.5))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 유틸

    private func colorForLabel(_ label: String) -> NSColor {
        let hash = abs(label.hashValue)
        let hue = CGFloat(hash % 360) / 360.0
        return NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1.0)
    }
}
