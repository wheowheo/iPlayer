import QuartzCore
import AppKit

final class DetectionOverlayLayer: CALayer {
    var result: DetectionResult = .empty { didSet { setNeedsDisplay() } }
    var detectionState: DetectionState = .idle { didSet { setNeedsDisplay() } }
    var detectionFPS: Double = 0 { didSet { setNeedsDisplay() } }
    var activeMode: DetectorMode = .objectDetection { didSet { setNeedsDisplay() } }
    var hideStatusBadge = false { didSet { setNeedsDisplay() } }

    override init() {
        super.init()
        isOpaque = false
        needsDisplayOnBoundsChange = true
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
    }
    override init(layer: Any) {
        super.init(layer: layer)
        if let o = layer as? DetectionOverlayLayer {
            result = o.result; detectionState = o.detectionState
            detectionFPS = o.detectionFPS; activeMode = o.activeMode; hideStatusBadge = o.hideStatusBadge
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        let b = self.bounds
        guard !b.isEmpty else { return }

        switch result {
        case .objects(let v):      drawObjects(v, in: ctx, bounds: b)
        case .poses(let v):        drawSkeleton(v, in: ctx, bounds: b)
        case .depthMap(let img):   ctx.draw(img, in: b)
        case .faces(let v):        drawFaces(v, in: ctx, bounds: b)
        case .hands(let v):        drawHands(v, in: ctx, bounds: b)
        case .texts(let v):        drawTexts(v, in: ctx, bounds: b)
        case .segmentation(let img): ctx.draw(img, in: b)
        case .faceSwap(let entries): drawFaceSwap(entries, in: ctx, bounds: b)
        case .empty: break
        }

        if !hideStatusBadge { drawStatusBadge(in: ctx, bounds: b) }
    }

    // MARK: - 객체 탐지

    private func drawObjects(_ objects: [DetectedObject], in ctx: CGContext, bounds: CGRect) {
        for det in objects {
            let rect = toRect(det.boundingBox, in: bounds)
            let color = colorForLabel(det.label)
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(2); ctx.stroke(rect)
            drawLabel("\(det.label) \(Int(det.confidence * 100))%", at: CGPoint(x: rect.minX, y: rect.maxY), color: color, in: ctx)
        }
    }

    // MARK: - 자세 추정 (스켈레톤)

    private func drawSkeleton(_ poses: [PoseResult], in ctx: CGContext, bounds: CGRect) {
        for pose in poses {
            ctx.setStrokeColor(NSColor.systemGreen.cgColor); ctx.setLineWidth(3); ctx.setLineCap(.round)
            for (fi, ti) in pose.connections {
                let p1 = toPoint(pose.joints[fi].location, in: bounds)
                let p2 = toPoint(pose.joints[ti].location, in: bounds)
                ctx.move(to: p1); ctx.addLine(to: p2)
            }
            ctx.strokePath()
            for j in pose.joints where j.confidence > 0.1 {
                drawJoint(at: toPoint(j.location, in: bounds), radius: 5, fill: .systemYellow, in: ctx)
            }
        }
    }

    // MARK: - 얼굴 랜드마크

    private func drawFaces(_ faces: [FaceResult], in ctx: CGContext, bounds: CGRect) {
        for face in faces {
            let faceRect = toRect(face.boundingBox, in: bounds)

            // 얼굴 영역 박스
            ctx.setStrokeColor(NSColor.systemPink.cgColor); ctx.setLineWidth(2); ctx.stroke(faceRect)

            // 랜드마크 포인트 (얼굴 bbox 기준 → 화면 좌표 변환)
            ctx.setFillColor(NSColor.systemGreen.withAlphaComponent(0.8).cgColor)
            for pt in face.landmarks {
                let x = faceRect.minX + pt.x * faceRect.width
                let y = faceRect.minY + pt.y * faceRect.height
                ctx.fillEllipse(in: CGRect(x: x - 1.5, y: y - 1.5, width: 3, height: 3))
            }

            // 윤곽선
            drawFaceRegion(face.faceContour, faceRect: faceRect, color: .white, in: ctx)
            drawFaceRegion(face.leftEye, faceRect: faceRect, color: .systemCyan, in: ctx)
            drawFaceRegion(face.rightEye, faceRect: faceRect, color: .systemCyan, in: ctx)
            drawFaceRegion(face.leftEyebrow, faceRect: faceRect, color: .systemMint, in: ctx)
            drawFaceRegion(face.rightEyebrow, faceRect: faceRect, color: .systemMint, in: ctx)
            drawFaceRegion(face.nose, faceRect: faceRect, color: .systemYellow, in: ctx)
            drawFaceRegion(face.outerLips, faceRect: faceRect, color: .systemRed, in: ctx)
            drawFaceRegion(face.innerLips, faceRect: faceRect, color: .systemOrange, in: ctx)

            // 표정 레이블
            drawLabel(face.expression.rawValue,
                      at: CGPoint(x: faceRect.minX, y: faceRect.maxY),
                      color: .systemPink, in: ctx)
        }
    }

    private func drawFaceRegion(_ points: [CGPoint], faceRect: CGRect, color: NSColor, in ctx: CGContext) {
        guard points.count >= 2 else { return }
        ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(1.5)
        for (i, pt) in points.enumerated() {
            let p = CGPoint(x: faceRect.minX + pt.x * faceRect.width,
                            y: faceRect.minY + pt.y * faceRect.height)
            if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
        }
        ctx.strokePath()
    }

    // MARK: - 손 추적

    private func drawHands(_ hands: [HandResult], in ctx: CGContext, bounds: CGRect) {
        let colors: [NSColor] = [.systemOrange, .systemPurple, .systemTeal, .systemPink]
        for (hi, hand) in hands.enumerated() {
            let color = colors[hi % colors.count]
            ctx.setStrokeColor(color.cgColor); ctx.setLineWidth(2.5); ctx.setLineCap(.round)
            for (fi, ti) in hand.connections {
                let p1 = toPoint(hand.joints[fi].location, in: bounds)
                let p2 = toPoint(hand.joints[ti].location, in: bounds)
                ctx.move(to: p1); ctx.addLine(to: p2)
            }
            ctx.strokePath()
            for j in hand.joints where j.confidence > 0.1 {
                drawJoint(at: toPoint(j.location, in: bounds), radius: 4, fill: .white, in: ctx)
            }
        }
    }

    // MARK: - 텍스트 인식

    private func drawTexts(_ texts: [TextResult], in ctx: CGContext, bounds: CGRect) {
        for t in texts {
            let rect = toRect(t.boundingBox, in: bounds)
            ctx.setStrokeColor(NSColor.systemYellow.cgColor); ctx.setLineWidth(1.5); ctx.stroke(rect)
            drawLabel(t.text, at: CGPoint(x: rect.minX, y: rect.maxY), color: .systemYellow, in: ctx)
        }
    }

    // MARK: - 얼굴 합성

    private func drawFaceSwap(_ entries: [FaceSwapEntry], in ctx: CGContext, bounds: CGRect) {
        for entry in entries {
            let targetRect = toRect(entry.targetRect, in: bounds)
            let maskRect = toRect(entry.maskRect, in: bounds)

            ctx.saveGState()

            // 타원형 클리핑 마스크 (부드러운 가장자리)
            let maskPath = CGPath(ellipseIn: maskRect, transform: nil)
            ctx.addPath(maskPath)
            ctx.clip()

            // 워핑된 얼굴 그리기
            ctx.draw(entry.warpedFace, in: targetRect)

            ctx.restoreGState()

            // 합성 영역 테두리 (디버그용, 반투명)
            ctx.setStrokeColor(NSColor.systemPurple.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: maskRect)
        }
    }

    // MARK: - 상태 배지

    private func drawStatusBadge(in ctx: CGContext, bounds: CGRect) {
        let text: String; let badgeColor: NSColor
        switch detectionState {
        case .idle: return
        case .detecting:
            let fps = detectionFPS > 0 ? String(format: " %.0f fps", detectionFPS) : ""
            text = "● \(activeMode.rawValue)\(fps)"; badgeColor = .systemGreen
        case .deferred:
            text = "◐ 탐지 대기"; badgeColor = .systemOrange
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: badgeColor]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let sz = attrStr.size(); let pad: CGFloat = 6
        let rect = CGRect(x: pad, y: bounds.height - sz.height - pad * 2, width: sz.width + pad * 2, height: sz.height + pad)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)); ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attrStr.draw(at: CGPoint(x: rect.minX + pad, y: rect.minY + pad * 0.5))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - 유틸

    private func toRect(_ normalized: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(x: normalized.origin.x * bounds.width, y: normalized.origin.y * bounds.height,
               width: normalized.width * bounds.width, height: normalized.height * bounds.height)
    }

    private func toPoint(_ normalized: CGPoint, in bounds: CGRect) -> CGPoint {
        CGPoint(x: normalized.x * bounds.width, y: normalized.y * bounds.height)
    }

    private func drawJoint(at pt: CGPoint, radius: CGFloat, fill: NSColor, in ctx: CGContext) {
        let circle = CGRect(x: pt.x - radius, y: pt.y - radius, width: radius * 2, height: radius * 2)
        ctx.setFillColor(fill.cgColor); ctx.fillEllipse(in: circle)
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: circle)
    }

    private func drawLabel(_ text: String, at point: CGPoint, color: NSColor, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let sz = attrStr.size()
        let rect = CGRect(x: point.x, y: point.y, width: sz.width + 8, height: sz.height + 4)
        ctx.setFillColor(color.withAlphaComponent(0.75).cgColor); ctx.fill(rect)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        attrStr.draw(at: CGPoint(x: rect.minX + 4, y: rect.minY + 2))
        NSGraphicsContext.restoreGraphicsState()
    }

    private func colorForLabel(_ label: String) -> NSColor {
        NSColor(hue: CGFloat(abs(label.hashValue) % 360) / 360.0, saturation: 0.8, brightness: 0.9, alpha: 1)
    }
}
