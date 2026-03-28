import SceneKit
import AppKit
import ModelIO

/// 3D 얼굴 렌더러 — SceneKit 기반
/// 2D 이미지 → 원통형 메시 매핑 또는 .obj/.usdz 3D 모델 로드
final class FaceRenderer3D {
    private let renderer: SCNRenderer
    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let faceNode = SCNNode()
    private let lightNode = SCNNode()
    private let ambientNode = SCNNode()

    private let renderSize: CGFloat = 512

    init() {
        renderer = SCNRenderer(device: nil, options: nil)
        renderer.scene = scene
        renderer.autoenablesDefaultLighting = false

        // 카메라 (FLAME 모델 크기에 최적화)
        let camera = SCNCamera()
        camera.usesOrthographicProjection = false
        camera.fieldOfView = 12
        camera.zNear = 0.01
        camera.zFar = 100
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 1.5)
        scene.rootNode.addChildNode(cameraNode)

        // 조명: 방향광
        let light = SCNLight()
        light.type = .directional
        light.intensity = 800
        light.color = NSColor.white
        lightNode.light = light
        lightNode.position = SCNVector3(2, 2, 3)
        lightNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(lightNode)

        // 환경광
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 400
        ambient.color = NSColor.white
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        scene.rootNode.addChildNode(faceNode)
        scene.background.contents = NSColor.clear
    }

    /// 2D 이미지를 내장 3D 얼굴 메시에 매핑
    func loadFromImage(_ image: NSImage) {
        faceNode.childNodes.forEach { $0.removeFromParentNode() }
        faceNode.geometry = nil

        // 내장 얼굴 메시 로드 시도
        if let meshURL = findBuiltInMesh(), let meshScene = try? SCNScene(url: meshURL, options: nil),
           let meshNode = meshScene.rootNode.childNodes.first, let meshGeo = meshNode.geometry {
            let geometry = meshGeo.copy() as! SCNGeometry
            let mat = SCNMaterial()
            mat.diffuse.contents = image
            mat.lightingModel = .phong
            mat.isDoubleSided = true
            geometry.materials = [mat]
            faceNode.geometry = geometry
            log("[3DFace] 내장 메시 로드: \(meshURL.lastPathComponent)")
        } else {
            let geometry = createCylindricalFaceMesh()
            let mat = SCNMaterial()
            mat.diffuse.contents = image
            mat.lightingModel = .phong
            mat.isDoubleSided = true
            geometry.materials = [mat]
            faceNode.geometry = geometry
            log("[3DFace] 절차적 메시 생성")
        }

        // 바운딩 박스로 정규화 — 메시 크기에 관계없이 화면에 꽉 차게
        let (minB, maxB) = faceNode.boundingBox
        let sizeX = maxB.x - minB.x
        let sizeY = maxB.y - minB.y
        let sizeZ = maxB.z - minB.z
        let maxDim = max(sizeX, max(sizeY, sizeZ))
        if maxDim > 0 {
            let s = 0.3 / maxDim  // 카메라 FOV=12, z=1.5에 맞는 스케일
            faceNode.scale = SCNVector3(s, s, s)
        }
        // 중심 보정
        let cx = (minB.x + maxB.x) / 2
        let cy = (minB.y + maxB.y) / 2
        let cz = (minB.z + maxB.z) / 2
        faceNode.pivot = SCNMatrix4MakeTranslation(cx, cy, cz)
    }

    private func findBuiltInMesh() -> URL? {
        // FLAME 우선, 없으면 절차적 메시 폴백
        let names = ["flame_face", "face_mesh"]
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        if let bundle = Bundle(url: execURL.appendingPathComponent("iPlayer_iPlayer.bundle")) {
            for name in names {
                if let url = bundle.url(forResource: name, withExtension: "obj") { return url }
            }
        }
        let srcRes = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources")
        for name in names {
            let url = srcRes.appendingPathComponent("\(name).obj")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// .obj 또는 .usdz 3D 모델 로드
    func loadFromFile(_ url: URL) -> Bool {
        faceNode.childNodes.forEach { $0.removeFromParentNode() }
        faceNode.geometry = nil

        do {
            let modelScene = try SCNScene(url: url, options: [
                .checkConsistency: true
            ])
            // 모든 자식 노드를 faceNode로 이동
            for child in modelScene.rootNode.childNodes {
                faceNode.addChildNode(child.clone())
            }
            // 바운딩 박스로 정규화
            let (minBound, maxBound) = faceNode.boundingBox
            let size = SCNVector3(
                maxBound.x - minBound.x,
                maxBound.y - minBound.y,
                maxBound.z - minBound.z
            )
            let maxDim = max(size.x, max(size.y, size.z))
            if maxDim > 0 {
                let s = 2.0 / maxDim
                faceNode.scale = SCNVector3(s, s, s)
            }
            let center = SCNVector3(
                (minBound.x + maxBound.x) / 2,
                (minBound.y + maxBound.y) / 2,
                (minBound.z + maxBound.z) / 2
            )
            faceNode.pivot = SCNMatrix4MakeTranslation(center.x, center.y, center.z)

            log("[3DFace] 모델 로드: \(url.lastPathComponent)")
            return true
        } catch {
            log("[3DFace] 모델 로드 실패: \(error)")
            return false
        }
    }

    /// 머리 포즈에 따라 3D 렌더링
    func render(roll: CGFloat, yaw: CGFloat, pitch: CGFloat) -> CGImage? {
        // 얼굴 노드 회전 (라디안)
        faceNode.eulerAngles = SCNVector3(
            Float(-pitch),   // X축: 상하 끄덕임
            Float(-yaw),     // Y축: 좌우 돌림
            Float(-roll)     // Z축: 좌우 기울임
        )

        // 렌더링
        let size = CGSize(width: renderSize, height: renderSize)
        let image = renderer.snapshot(atTime: 0, with: size,
                                       antialiasingMode: .multisampling4X)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - 원통형 얼굴 메시 생성

    private func createCylindricalFaceMesh() -> SCNGeometry {
        let cols = 32
        let rows = 40
        let width: Float = 2.0
        let height: Float = 2.5
        let curveDepth: Float = 0.6  // 원통 곡률

        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var texCoords: [CGPoint] = []
        var indices: [Int32] = []

        for row in 0...rows {
            let v = Float(row) / Float(rows)
            let y = height * (v - 0.5)

            for col in 0...cols {
                let u = Float(col) / Float(cols)
                let angle = (u - 0.5) * Float.pi * 0.8  // 원통 각도 범위

                let x = sin(angle) * (width / 2)
                let z = (cos(angle) - 1) * curveDepth

                // 코 돌출
                let noseFactor = noseProfile(u: u, v: v)
                let zWithNose = z - noseFactor * 0.15

                vertices.append(SCNVector3(x, y, zWithNose))

                // 법선
                let nx = sin(angle)
                let nz = cos(angle)
                normals.append(SCNVector3(nx, 0, nz))

                texCoords.append(CGPoint(x: CGFloat(u), y: CGFloat(1 - v)))
            }
        }

        // 삼각형 인덱스
        for row in 0..<rows {
            for col in 0..<cols {
                let tl = Int32(row * (cols + 1) + col)
                let tr = tl + 1
                let bl = Int32((row + 1) * (cols + 1) + col)
                let br = bl + 1
                indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        let vertexSource = SCNGeometrySource(vertices: vertices)
        let normalSource = SCNGeometrySource(normals: normals)
        let texSource = SCNGeometrySource(textureCoordinates: texCoords)
        let element = SCNGeometryElement(indices: indices, primitiveType: .triangles)

        return SCNGeometry(sources: [vertexSource, normalSource, texSource], elements: [element])
    }

    /// 코 돌출 프로파일 (가우시안)
    private func noseProfile(u: Float, v: Float) -> Float {
        let cx: Float = 0.5, cy: Float = 0.55
        let dx = u - cx, dy = v - cy
        let sigmaX: Float = 0.08, sigmaY: Float = 0.12
        return exp(-(dx * dx) / (2 * sigmaX * sigmaX) - (dy * dy) / (2 * sigmaY * sigmaY))
    }
}
