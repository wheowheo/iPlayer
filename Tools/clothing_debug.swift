#!/usr/bin/env swift
// 옷 입어보기 좌표 매핑 검증 도구 (SceneKit 없이 좌표만 검증)
import AppKit
import Vision
import CoreGraphics

func detectPose(in image: CGImage) -> [(String, CGFloat, CGFloat, Float)]? {
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    let request = VNDetectHumanBodyPoseRequest()
    try? handler.perform([request])
    guard let obs = request.results?.first else { return nil }

    let names: [(VNHumanBodyPoseObservation.JointName, String)] = [
        (.nose,"nose"),(.neck,"neck"),
        (.leftShoulder,"lShoulder"),(.rightShoulder,"rShoulder"),
        (.leftElbow,"lElbow"),(.rightElbow,"rElbow"),
        (.leftWrist,"lWrist"),(.rightWrist,"rWrist"),
        (.root,"root"),
        (.leftHip,"lHip"),(.rightHip,"rHip"),
        (.leftKnee,"lKnee"),(.rightKnee,"rKnee"),
        (.leftAnkle,"lAnkle"),(.rightAnkle,"rAnkle"),
    ]
    return names.map { (vn, name) in
        if let pt = try? obs.recognizedPoint(vn), pt.confidence > 0.1 {
            return (name, pt.location.x, pt.location.y, Float(pt.confidence))
        }
        return (name, CGFloat(0), CGFloat(0), Float(0))
    }
}

let imagePath = CommandLine.arguments.count >= 2 ? CommandLine.arguments[1] : "Sample/pose_test.jpg"
let outputDir = CommandLine.arguments.count >= 3 ? CommandLine.arguments[2] : "/tmp/clothing_debug"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let img = NSImage(contentsOfFile: imagePath)!
let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)!
let w = CGFloat(cg.width), h = CGFloat(cg.height)

print("=== 옷 입어보기 좌표 검증 ===")
print("이미지: \(Int(w))x\(Int(h))\n")

guard let joints = detectPose(in: cg) else { print("자세 감지 실패"); exit(1) }

print("=== 관절 좌표 (Vision y-up) ===")
for (i, j) in joints.enumerated() {
    let mark = j.3 > 0.1 ? "✓" : "✗"
    let padded = j.0.padding(toLength: 12, withPad: " ", startingAt: 0)
    print("  [\(String(format:"%2d",i))] \(padded) norm=(\(String(format:"%.3f",j.1)),\(String(format:"%.3f",j.2)))  pixel=(\(Int(j.1*w)),\(Int((1-j.2)*h))) \(mark)")
}

// Y축 방향 검증
print("\n=== Y축 방향 ===")
let noseY = joints[0].2, neckY = joints[1].2
print("  코 y=\(String(format:"%.3f",noseY))  목 y=\(String(format:"%.3f",neckY))")
print("  코 > 목 → \(noseY > neckY ? "y-up 정상 ✓" : "반전됨 ✗")")

if joints[9].3 > 0.1 {
    let shoulderY = joints[2].2, hipY = joints[9].2
    print("  어깨 y=\(String(format:"%.3f",shoulderY))  엉덩이 y=\(String(format:"%.3f",hipY))")
    print("  어깨 > 엉덩이 → \(shoulderY > hipY ? "y-up 정상 ✓" : "반전됨 ✗")")
}

// 의류 타입별 매핑 영역 계산 + 시각화
func pt(_ i: Int) -> (CGFloat, CGFloat)? {
    guard joints[i].3 > 0.1 else { return nil }
    return (joints[i].1 * w, (1 - joints[i].2) * h)  // CGContext y-down
}

let ctx = CGContext(data: nil, width: Int(w), height: Int(h),
                    bitsPerComponent: 8, bytesPerRow: Int(w)*4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x:0,y:0,width:w,height:h))

// 스켈레톤 그리기
let conns = [(0,1),(1,2),(1,3),(2,4),(4,6),(3,5),(5,7),(1,8),(8,9),(8,10),(9,11),(11,13),(10,12),(12,14)]
ctx.setStrokeColor(NSColor.green.cgColor); ctx.setLineWidth(3)
for (a,b) in conns {
    if let pa = pt(a), let pb = pt(b) {
        ctx.move(to: CGPoint(x:pa.0,y:pa.1)); ctx.addLine(to: CGPoint(x:pb.0,y:pb.1))
    }
}
ctx.strokePath()

// 관절 포인트 + 번호
for (i,j) in joints.enumerated() where j.3 > 0.1 {
    let px = j.1*w, py = (1-j.2)*h
    ctx.setFillColor(NSColor.red.cgColor); ctx.fillEllipse(in: CGRect(x:px-6,y:py-6,width:12,height:12))
    ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: CGRect(x:px-4,y:py-4,width:8,height:8))
}

// 의류 영역 표시
print("\n=== 의류 매핑 영역 ===")

// 모자: 코 위
if let nose = pt(0), let neck = pt(1) {
    let headH = abs(nose.1 - neck.1) * 1.2
    let headW = headH * 1.8
    let hatRect = CGRect(x: nose.0-headW/2, y: nose.1-headH, width: headW, height: headH)
    ctx.setStrokeColor(NSColor.brown.cgColor); ctx.setLineWidth(3); ctx.stroke(hatRect)
    print("  모자: (\(Int(hatRect.minX)),\(Int(hatRect.minY))) \(Int(hatRect.width))x\(Int(hatRect.height)) [코 위]")
}

// 상의: 어깨→엉덩이
if let ls = pt(2), let rs = pt(3) {
    let lh = pt(9), rh = pt(10)
    let top = min(ls.1, rs.1)
    let bot = max(lh?.1 ?? top+150, rh?.1 ?? top+150)
    let left = min(ls.0, rs.0)
    let right = max(ls.0, rs.0)
    let bw = right-left, bh = bot-top
    let topRect = CGRect(x:left-bw*0.25, y:top-bh*0.05, width:bw*1.5, height:bh*1.15)
    ctx.setStrokeColor(NSColor.systemBlue.cgColor); ctx.setLineWidth(3)
    ctx.setLineDash(phase:0, lengths:[8,4]); ctx.stroke(topRect); ctx.setLineDash(phase:0, lengths:[])
    print("  상의: (\(Int(topRect.minX)),\(Int(topRect.minY))) \(Int(topRect.width))x\(Int(topRect.height)) [어깨→엉덩이]")
}

// 하의: 엉덩이→발목
if let lh = pt(9), let rh = pt(10) {
    let la = pt(13) ?? pt(11)
    let ra = pt(14) ?? pt(12)
    if let la = la, let ra = ra {
        let top2 = min(lh.1, rh.1)
        let bot2 = max(la.1, ra.1)
        let left2 = min(lh.0,rh.0,la.0,ra.0)
        let right2 = max(lh.0,rh.0,la.0,ra.0)
        let bw2 = right2-left2
        let bottomRect = CGRect(x:left2-bw2*0.2, y:top2, width:bw2*1.4, height:bot2-top2)
        ctx.setStrokeColor(NSColor.systemOrange.cgColor); ctx.setLineWidth(3)
        ctx.setLineDash(phase:0, lengths:[8,4]); ctx.stroke(bottomRect); ctx.setLineDash(phase:0, lengths:[])
        print("  하의: (\(Int(bottomRect.minX)),\(Int(bottomRect.minY))) \(Int(bottomRect.width))x\(Int(bottomRect.height)) [엉덩이→발목]")
    }
}

let out = "\(outputDir)/clothing_regions.png"
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath:out) as CFURL,"public.png" as CFString,1,nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
print("\n저장: \(out)")
