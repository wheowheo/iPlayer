import SceneKit
import AppKit

/// 의류 3D 렌더러 — SceneKit 기반, 자세에 맞춰 렌더링
final class ClothingRenderer3D {
    private let renderer: SCNRenderer
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let clothNode = SCNNode()
    private var currentModelFile: String = ""
    private let renderSize: CGFloat = 512

    init() {
        renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false

        let camera = SCNCamera()
        camera.usesOrthographicProjection = false
        camera.fieldOfView = 35
        camera.zNear = 0.01
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 3)
        scene.rootNode.addChildNode(cameraNode)

        let light = SCNLight()
        light.type = .directional
        light.intensity = 900
        let ln = SCNNode()
        ln.light = light
        ln.position = SCNVector3(1, 2, 3)
        ln.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(ln)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 400
        let an = SCNNode()
        an.light = ambient
        scene.rootNode.addChildNode(an)

        scene.rootNode.addChildNode(clothNode)
        scene.background.contents = NSColor.clear
    }

    /// 의류 모델 로드 (파일이 변경된 경우만)
    func loadModel(item: ClothingItem) {
        guard !item.modelFile.isEmpty, item.modelFile != currentModelFile else {
            // 같은 모델이면 색상만 업데이트
            updateColor(item: item)
            return
        }

        clothNode.childNodes.forEach { $0.removeFromParentNode() }
        clothNode.geometry = nil

        guard let url = findClothingModel(item.modelFile) else {
            log("[ClothingRenderer] 모델 없음: \(item.modelFile)")
            return
        }

        guard let modelScene = try? SCNScene(url: url, options: nil) else {
            log("[ClothingRenderer] 로드 실패: \(item.modelFile)")
            return
        }

        for child in modelScene.rootNode.childNodes {
            clothNode.addChildNode(child.clone())
        }

        // 바운딩 박스로 정규화
        let (mi, ma) = clothNode.boundingBox
        let maxDim = max(ma.x - mi.x, max(ma.y - mi.y, ma.z - mi.z))
        if maxDim > 0 {
            let s = 1.8 / maxDim
            clothNode.scale = SCNVector3(s, s, s)
        }
        clothNode.pivot = SCNMatrix4MakeTranslation(
            (mi.x + ma.x) / 2, (mi.y + ma.y) / 2, (mi.z + ma.z) / 2
        )

        currentModelFile = item.modelFile
        updateColor(item: item)
        log("[ClothingRenderer] 로드: \(item.modelFile)")
    }

    /// 색상 업데이트
    private func updateColor(item: ClothingItem) {
        let c = item.color
        let color = NSColor(red: c.r, green: c.g, blue: c.b, alpha: CGFloat(item.opacity))
        clothNode.enumerateChildNodes { node, _ in
            if let geo = node.geometry {
                let mat = SCNMaterial()
                mat.diffuse.contents = color
                mat.lightingModel = .phong
                mat.isDoubleSided = true
                geo.materials = [mat]
            }
        }
    }

    /// 자세에 맞춰 렌더링 → CGImage 반환
    func render(shoulderLeft: CGPoint?, shoulderRight: CGPoint?, hip: CGPoint?) -> CGImage? {
        // 어깨 기울기로 회전 추정
        var roll: Float = 0
        if let ls = shoulderLeft, let rs = shoulderRight {
            roll = Float(atan2(rs.y - ls.y, rs.x - ls.x))
        }

        clothNode.eulerAngles = SCNVector3(0, 0, -roll)

        let img = renderer.snapshot(atTime: 0, with: CGSize(width: renderSize, height: renderSize),
                                     antialiasingMode: .multisampling4X)
        return img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    /// 정적 미리보기 렌더 (옷장 관리용)
    func renderPreview(item: ClothingItem, size: CGSize = CGSize(width: 80, height: 100)) -> NSImage? {
        loadModel(item: item)
        clothNode.eulerAngles = SCNVector3(0, Float.pi * -0.15, 0)  // 약간 회전
        let img = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return img
    }

    private func findClothingModel(_ filename: String) -> URL? {
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        if let bundle = Bundle(url: execURL.appendingPathComponent("iPlayer_iPlayer.bundle")) {
            if let url = bundle.url(forResource: (filename as NSString).deletingPathExtension,
                                     withExtension: (filename as NSString).pathExtension,
                                     subdirectory: "clothes") { return url }
        }
        for dir in [execURL.appendingPathComponent("Resources/clothes"),
                    URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources/clothes")] {
            let url = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }
}
