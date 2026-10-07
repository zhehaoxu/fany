#!/usr/bin/env swift
//
//  generate_fan_icons.swift
//  生成状态栏风扇图标的 24 帧 PNG 序列（frame_0 ~ frame_23），
//  并自动写入 fany/Assets.xcassets 下的 .imageset 目录（template 渲染模式）。
//
//  风扇本体形状参照 cartoon-fan-hub.svg：脚本内置该 SVG 的路径数据，
//  用轻量 SVG path 解析器（M/m L/l C/c Z/z）重建轮廓后按帧旋转填充。
//  第 0 帧为静止图标；帧序递增时风扇顺时针旋转，无吹风效果。
//
//  用法: swift scripts/generate_fan_icons.swift [Assets.xcassets 路径]
//

import AppKit

// MARK: - 配置

let frameCount = 24                 // 总帧数，每帧旋转 360/24 = 15°；与三叶 120° 对称整除（8 帧一循环），转动无周期性跳动
let baseDiameter: CGFloat = 22      // 1x 逻辑尺寸（pt），接近菜单栏高度，图标显得更大
let scales = [1, 2, 3]              // 对应 1x / 2x / 3x

let assetsDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "\(FileManager.default.currentDirectoryPath)/fany/Assets.xcassets")

// MARK: - cartoon-fan-hub.svg 路径数据
//
// 原 SVG: viewBox="-0.0 -1.0 273.0 273.0"
//         <g transform="translate(0,271) scale(0.1,-0.1)"> —— 等价于点变换 (x, y) -> (0.1x, 271 - 0.1y)

let svgPathD = """
M1137 2519 c-274 -40 -497 -201 -567 -409 -86 -255 78 -606 338 -722
37 -17 43 -23 38 -41 -3 -12 -6 -55 -6 -95 0 -70 -1 -73 -27 -83 -68 -26 -143
-30 -294 -14 -224 23 -315 -2 -385 -107 -84 -124 -55 -318 73 -509 141 -208
365 -344 589 -357 143 -7 226 23 333 123 75 70 126 152 163 264 28 85 31 109
32 213 l0 117 27 6 c15 4 53 24 83 45 l56 40 42 -38 c58 -51 109 -135 152
-245 47 -121 84 -178 143 -221 61 -44 118 -60 191 -54 84 8 147 42 227 123 92
92 157 217 186 361 27 129 23 287 -10 384 -43 127 -140 240 -258 299 -176 88
-490 75 -639 -26 -30 -20 -42 -23 -54 -14 -8 6 -39 25 -69 43 l-53 31 6 41 c9
56 54 148 116 241 82 121 114 198 118 282 4 60 0 80 -21 126 -73 160 -272 234
-530 196z m291 -104 c140 -42 204 -162 154 -292 -10 -27 -47 -91 -82 -143 -65
-97 -129 -235 -130 -280 0 -40 -11 -47 -85 -53 -92 -9 -176 -50 -242 -120 -27
-29 -52 -59 -54 -66 -8 -23 -106 36 -175 105 -66 67 -122 164 -149 258 -28 95
-17 227 24 311 57 115 166 202 324 256 143 49 299 58 415 24z m18 -877 c56
-26 106 -74 136 -131 19 -35 23 -58 23 -137 0 -85 -3 -100 -27 -141 -63 -107
-141 -154 -258 -154 -91 0 -149 24 -210 85 -166 166 -88 442 144 501 48 13
141 2 192 -23z m662 17 c237 -56 368 -245 347 -502 -16 -214 -122 -421 -255
-500 -44 -27 -65 -33 -111 -33 -49 0 -63 5 -100 33 -58 45 -72 66 -124 192
-53 128 -116 226 -178 275 l-44 35 26 55 c21 47 25 70 25 155 1 89 -2 107 -27
159 -15 32 -27 60 -27 62 0 14 121 60 205 78 48 10 205 4 263 -9z m-1121 -477
c41 -89 181 -181 293 -194 l60 -7 0 -76 c-1 -168 -54 -305 -160 -412 -92 -92
-140 -113 -260 -113 -73 0 -110 5 -160 23 -205 71 -393 260 -460 461 -31 93
-26 192 13 243 53 70 109 81 303 61 149 -15 230 -10 309 20 52 19 50 19 62 -6z
M1232 1439 c-75 -37 -115 -124 -98 -214 14 -71 107 -145 186 -145 78 0 159 62
180 138 14 52 12 81 -9 127 -48 104 -158 144 -259 94z
"""

// MARK: - 轻量 SVG path 解析（支持 M/m L/l C/c Z/z 及隐式重复参数）

struct FanShape {
    let path: CGPath        // SVG 用户坐标系（y 向下）
    let bbox: CGRect
}

func parseFanShape(from d: String) -> FanShape {
    // 分词：命令字母与数字
    enum Token { case cmd(Character), num(CGFloat) }
    var tokens: [Token] = []
    var numBuf = ""
    func flushNum() {
        if !numBuf.isEmpty, let v = Double(numBuf) {
            tokens.append(.num(CGFloat(v)))
            numBuf = ""
        }
    }
    for ch in d {
        if ch.isLetter {
            flushNum()
            tokens.append(.cmd(ch))
        } else if ch == "," || ch == " " || ch == "\n" || ch == "\t" || ch == "\r" {
            flushNum()
        } else {
            numBuf.append(ch)
        }
    }
    flushNum()

    // 组变换 (x, y) -> (0.1x, 271 - 0.1y)，把原始坐标转成 SVG 用户坐标
    func user(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * 0.1, y: 271 - p.y * 0.1) }

    let out = CGMutablePath()
    var cur = CGPoint.zero          // 原始坐标系游标（相对命令以此为基准）
    var subpathStart = CGPoint.zero
    var cmd: Character = " "
    var idx = 0
    var minX = CGFloat.greatestFiniteMagnitude, minY = minX
    var maxX = -minX, maxY = -minX
    func track(_ p: CGPoint) {
        minX = min(minX, p.x); maxX = max(maxX, p.x)
        minY = min(minY, p.y); maxY = max(maxY, p.y)
    }
    func num(_ offset: Int = 0) -> CGFloat {
        guard case .num(let v)? = tokens[safe: idx + offset] else { return 0 }
        return v
    }
    func take() { idx += 1 }

    while idx < tokens.count {
        if case .cmd(let c)? = tokens[safe: idx] {
            cmd = c
            take()
        }
        switch cmd {
        case "M", "L": // 绝对坐标；M 后续隐式按 L 处理
            let p = CGPoint(x: num(), y: num(1)); take(); take()
            if cmd == "M" { out.move(to: user(p)); subpathStart = p; cur = p; cmd = "L" }
            else { out.addLine(to: user(p)); cur = p }
            track(user(p))
        case "m", "l": // 相对坐标；m 后续隐式按 l 处理
            let dxy = CGPoint(x: num() + cur.x, y: num(1) + cur.y); take(); take()
            if cmd == "m" { out.move(to: user(dxy)); subpathStart = dxy; cmd = "l" }
            else { out.addLine(to: user(dxy)) }
            cur = dxy
            track(user(dxy))
        case "C": // 绝对三次贝塞尔（支持隐式重复）
            let c1 = CGPoint(x: num(), y: num(1))
            let c2 = CGPoint(x: num(2), y: num(3))
            let p = CGPoint(x: num(4), y: num(5)); take(); take(); take(); take(); take(); take()
            out.addCurve(to: user(p), control1: user(c1), control2: user(c2))
            cur = p
            track(user(p))
        case "c": // 相对三次贝塞尔（支持隐式重复）
            let c1 = CGPoint(x: num() + cur.x, y: num(1) + cur.y)
            let c2 = CGPoint(x: num(2) + cur.x, y: num(3) + cur.y)
            let p = CGPoint(x: num(4) + cur.x, y: num(5) + cur.y)
            take(); take(); take(); take(); take(); take()
            out.addCurve(to: user(p), control1: user(c1), control2: user(c2))
            cur = p
            track(user(p))
        case "Z", "z":
            out.closeSubpath()
            cur = subpathStart
        default:
            take() // 防御性推进，避免死循环
        }
    }

    let bbox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    return FanShape(path: out, bbox: bbox)
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

let fanShape = parseFanShape(from: svgPathD)

// MARK: - 绘制

/// 在给定 CGContext 中绘制一帧风扇（以画布中心为原点）
func drawFan(into ctx: CGContext, radius: CGFloat, rotationDegrees: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: radius, y: radius)
    ctx.rotate(by: rotationDegrees * .pi / 180)

    // 把 SVG 形状居中缩放到画布：外形占半径的 0.74
    let fit = radius * 0.74
    let scale = fit / max(fanShape.bbox.width, fanShape.bbox.height) * 2
    let center = CGPoint(x: fanShape.bbox.midX, y: fanShape.bbox.midY)
    ctx.scaleBy(x: scale, y: -scale)          // y 翻转：SVG(y 向下) -> Quartz(y 向上)
    ctx.translateBy(x: -center.x, y: -center.y)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.addPath(fanShape.path)
    ctx.fillPath(using: .winding)             // 对应 SVG 默认 nonzero 填充规则
    ctx.restoreGState()
}

/// 生成某一帧某一倍率的 PNG 数据
func renderFramePNG(index: Int, scale: Int) -> Data? {
    let px = Int(baseDiameter * CGFloat(scale))
    let size = NSSize(width: px, height: px)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(origin: .zero, size: size))
    // 负角度：Quartz 正角为逆时针，取反后帧序递增即顺时针旋转
    drawFan(into: ctx, radius: CGFloat(px) / 2,
            rotationDegrees: -CGFloat(index) * (360.0 / CGFloat(frameCount)))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

/// 写入 imageset 目录与 Contents.json（template 渲染）
func writeImageset(name: String, pngs: [(scale: Int, data: Data, filename: String)]) {
    let dir = assetsDir.appendingPathComponent("\(name).imageset")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    var imageEntries: [[String: String]] = []
    for entry in pngs {
        try? entry.data.write(to: dir.appendingPathComponent(entry.filename))
        imageEntries.append([
            "idiom": "universal",
            "scale": "\(entry.scale)x",
            "filename": entry.filename,
        ])
    }
    let contents: [String: Any] = [
        "images": imageEntries,
        "info": ["author": "xcode", "version": 1],
        "properties": ["template-rendering-intent": "template"],
    ]
    let json = (try? JSONSerialization.data(withJSONObject: contents,
                                            options: [.prettyPrinted, .sortedKeys])) ?? Data()
    try? json.write(to: dir.appendingPathComponent("Contents.json"))
}

// MARK: - 主流程

for i in 0..<frameCount {
    var pngs: [(scale: Int, data: Data, filename: String)] = []
    for s in scales {
        guard let data = renderFramePNG(index: i, scale: s) else { continue }
        pngs.append((s, data, "frame_\(i)_\(s)x.png"))
    }
    writeImageset(name: "frame_\(i)", pngs: pngs)
    print("✓ frame_\(i) (旋转 \(Int(Double(i) * 360.0 / Double(frameCount)))°, \(pngs.count) 个尺寸)")
}

print("\n完成：\(frameCount) 帧已写入 \(assetsDir.path)")
