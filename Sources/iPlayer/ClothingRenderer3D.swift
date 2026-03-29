import AppKit
import CoreImage

/// 의류 2D 워핑 렌더러 — 사전 렌더된 PNG를 관절 4점에 원근 변환
final class ClothingRenderer3D {
    private var cachedImages: [String: CGImage] = [:]
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 의류 PNG 로드 (캐시)
    func loadImage(for item: ClothingItem) -> CGImage? {
        let pngName = (item.modelFile as NSString).deletingPathExtension + ".png"

        if let cached = cachedImages[pngName] { return cached }

        guard let url = findClothingImage(pngName),
              let nsImg = NSImage(contentsOf: url),
              let cg = nsImg.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }

        cachedImages[pngName] = cg
        return cg
    }

    /// 관절 4점에 맞춰 원근 워핑 — CIPerspectiveTransform
    func warpToBody(image: CGImage, topLeft: CGPoint, topRight: CGPoint,
                    bottomLeft: CGPoint, bottomRight: CGPoint,
                    tintColor: (r: CGFloat, g: CGFloat, b: CGFloat)? = nil,
                    opacity: CGFloat = 0.85) -> CGImage? {
        var ci = CIImage(cgImage: image)

        // 색상 틴트 (흰색 렌더에 색 입히기)
        if let color = tintColor {
            let tintFilter = CIFilter(name: "CIColorMatrix")!
            tintFilter.setValue(ci, forKey: kCIInputImageKey)
            tintFilter.setValue(CIVector(x: color.r, y: 0, z: 0, w: 0), forKey: "inputRVector")
            tintFilter.setValue(CIVector(x: 0, y: color.g, z: 0, w: 0), forKey: "inputGVector")
            tintFilter.setValue(CIVector(x: 0, y: 0, z: color.b, w: 0), forKey: "inputBVector")
            tintFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: opacity), forKey: "inputAVector")
            if let out = tintFilter.outputImage { ci = out }
        }

        // 원근 변환: 이미지 4꼭짓점 → 신체 4점
        guard let filter = CIFilter(name: "CIPerspectiveTransform") else { return nil }
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)

        // CIImage 좌표는 y-up
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: output.extent)
    }

    /// 미리보기 (옷장 관리용) — PNG 축소 반환
    func renderPreview(item: ClothingItem, size: CGSize = CGSize(width: 48, height: 56)) -> NSImage? {
        guard let cg = loadImage(for: item) else { return nil }
        let nsImg = NSImage(size: size)
        nsImg.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let c = item.color
        NSColor(red: c.r, green: c.g, blue: c.b, alpha: 0.9).setFill()
        NSRect(origin: .zero, size: size).fill()
        NSImage(cgImage: cg, size: size).draw(in: NSRect(origin: .zero, size: size),
            from: .zero, operation: .destinationIn, fraction: 1.0)
        nsImg.unlockFocus()
        return nsImg
    }

    private func findClothingImage(_ filename: String) -> URL? {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        if let bundle = Bundle(url: execURL.appendingPathComponent("iPlayer_iPlayer.bundle")) {
            if let url = bundle.url(forResource: (filename as NSString).deletingPathExtension,
                                     withExtension: "png", subdirectory: "clothes") { return url }
        }
        for dir in [execURL.appendingPathComponent("Resources/clothes"),
                    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/clothes")] {
            let url = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
