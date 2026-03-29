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
        case .clothing(let poses, let item, let swipe): drawClothing(poses, item: item, swipe: swipe, in: ctx, bounds: b)
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

    // MARK: - 옷 입어보기

    // 3D 의류 렌더러 (지연 초기화)
    private lazy var clothingRenderer = ClothingRenderer3D()
    private var lastClothingId: Int64 = -1

    private func drawClothing(_ poses: [PoseResult], item: ClothingItem?, swipe: String?, in ctx: CGContext, bounds: CGRect) {
        // 스켈레톤 그리기 (반투명)
        for pose in poses {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.3).cgColor)
            ctx.setLineWidth(1.5); ctx.setLineCap(.round)
            for (fi, ti) in pose.connections {
                let p1 = toPoint(pose.joints[fi].location, in: bounds)
                let p2 = toPoint(pose.joints[ti].location, in: bounds)
                ctx.move(to: p1); ctx.addLine(to: p2)
            }
            ctx.strokePath()
        }

        guard let clothing = item, let pose = poses.first else { return }
        let joints = pose.joints
        // 인덱스: 0=nose,1=neck,2=lShoulder,3=rShoulder,...,8=root,9=lHip,10=rHip,...

        func pt(_ i: Int) -> CGPoint? {
            guard i < joints.count, joints[i].confidence > 0.1 else { return nil }
            return toPoint(joints[i].location, in: bounds)
        }

        // 3D 모델이 있으면 SceneKit 렌더링
        if !clothing.modelFile.isEmpty {
            if clothing.id != lastClothingId {
                clothingRenderer.loadModel(item: clothing)
                lastClothingId = clothing.id
            }

            if let rendered = clothingRenderer.render(
                shoulderLeft: pt(2), shoulderRight: pt(3), hip: pt(8)
            ) {
                // 의류 타입별 위치 결정
                // Vision y-up: 머리(y 큼) → 발(y 작음)
                let drawRect: CGRect

                switch clothing.type {
                case .hat:
                    // 머리 위: 코(0) 위쪽
                    if let nose = pt(0), let neck = pt(1) {
                        let headH = abs(nose.y - neck.y) * 1.2
                        let headW = headH * 1.8
                        drawRect = CGRect(x: nose.x - headW / 2, y: nose.y, width: headW, height: headH)
                    } else { return }

                case .bottom:
                    // 엉덩이 → 발목
                    if let lh = pt(9), let rh = pt(10) {
                        let la = pt(13) ?? pt(11) ?? lh
                        let ra = pt(14) ?? pt(12) ?? rh
                        let top = max(lh.y, rh.y)
                        let bot = min(la.y, ra.y)
                        let left = min(lh.x, rh.x, la.x, ra.x)
                        let right = max(lh.x, rh.x, la.x, ra.x)
                        let w = right - left
                        drawRect = CGRect(x: left - w * 0.2, y: bot, width: w * 1.4, height: top - bot)
                    } else { return }

                case .top, .fullBody, .accessory:
                    // 어깨 → 엉덩이 (상의/전신)
                    let ls = pt(2), rs = pt(3), lh = pt(9), rh = pt(10)
                    if let ls = ls, let rs = rs {
                        let top = max(ls.y, rs.y)
                        let bot: CGFloat
                        if clothing.type == .fullBody {
                            let la = pt(13) ?? pt(11)
                            let ra = pt(14) ?? pt(12)
                            bot = min(la?.y ?? (lh?.y ?? top - 200), ra?.y ?? (rh?.y ?? top - 200))
                        } else {
                            bot = min(lh?.y ?? top - 150, rh?.y ?? top - 150)
                        }
                        let left = min(ls.x, rs.x)
                        let right = max(ls.x, rs.x)
                        let bodyW = right - left
                        let bodyH = top - bot
                        drawRect = CGRect(x: left - bodyW * 0.25, y: bot - bodyH * 0.05,
                                          width: bodyW * 1.5, height: bodyH * 1.15)
                    } else { return }
                }

                ctx.draw(rendered, in: drawRect)
            }
        }

        // 옷 이름 표시 (하단 중앙)
        let nameStr = "\(clothing.name) (\(clothing.type.rawValue))"
        drawLabel(nameStr, at: CGPoint(x: (bounds.width - 100) / 2, y: 20), color: .systemBlue, in: ctx)

        // 스와이프 표시
        if let dir = swipe {
            drawLabel("스와이프 \(dir)", at: CGPoint(x: bounds.width / 2 - 40, y: bounds.height / 2), color: .systemYellow, in: ctx)
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
