//
//  FanIconRenderer.swift
//  fany
//
//  用 Core Graphics 实时绘制菜单栏风扇图标。
//  目前只有两种类型：默认四叶风扇、无叶风扇。
//

import AppKit

/// 传给渲染器的一帧画面状态
struct FanFrame {
    var type: FanType
    var angle: Double = 0           // 顺时针旋转角（弧度）
    var yaw: Double = 0             // 摇头偏航角（弧度）
    var phase: Double = 0           // 非旋转类动画进度 0...1
    var angularVelocity: Double = 0 // 当前角速度，用于动态模糊
}

final class FanIconRenderer {
    /// 菜单栏图标逻辑尺寸（pt）
    let pointSize: CGFloat
    /// 位图倍率；3x 在 2x/3x 屏幕上都有足够的细节
    let rasterScale: CGFloat

    private let context: CGContext
    private let radius: CGFloat
    private let defaultPetal: CGPath
    private let blowerRing: CGPath
    private let blowerStand: CGPath

    /// 默认风扇的描边约为外半径的 10%
    private let defaultOutlineWidth: CGFloat
    /// 线框拖影透明度
    private let lineGhostAlphas: [CGFloat] = [0.22, 0.13, 0.07]

    /// 无叶风扇的气流列：x 为水平位置，offset 为相位偏移（均归一化）
    private let airflowColumns: [(x: CGFloat, offset: CGFloat)] = [
        (-0.21, 0), (0, 0.34), (0.21, 0.67)
    ]

    init(pointSize: CGFloat = 18, rasterScale: CGFloat = 3) {
        self.pointSize = pointSize
        self.rasterScale = rasterScale
        let r = pointSize * 0.46
        radius = r

        // 默认风扇使用 0.45r 的轮廓半径，为 10% 描边留出边距
        defaultPetal = Self.makeDefaultPetal(radius: pointSize * 0.45)
        blowerRing = Self.makeBlowerRing(radius: r)
        blowerStand = Self.makeBlowerStand(radius: r)
        defaultOutlineWidth = pointSize * 0.045

        let pixels = Int(pointSize * rasterScale)
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("无法创建风扇图标的绘制上下文")
        }
        context = ctx
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.setLineCap(.round)
        context.setLineJoin(.round)
    }

    // MARK: - 输出

    func image(for frame: FanFrame) -> NSImage {
        let pixels = Int(pointSize * rasterScale)

        context.saveGState()
        context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
        context.scaleBy(x: rasterScale, y: rasterScale)
        context.translateBy(x: pointSize / 2, y: pointSize / 2)

        // 摇头：绕竖直轴旋转在二维上的正交投影就是水平压缩
        if abs(frame.yaw) > 0.0001 {
            context.scaleBy(x: CGFloat(cos(frame.yaw)), y: 1)
        }

        context.setAlpha(1)
        context.setFillColor(NSColor.black.cgColor)
        context.setStrokeColor(NSColor.black.cgColor)
        draw(frame, in: context)
        context.restoreGState()

        guard let cgImage = context.makeImage() else {
            return NSImage(size: NSSize(width: pointSize, height: pointSize))
        }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: pointSize, height: pointSize))
        image.isTemplate = true
        return image
    }

    // MARK: - 绘制入口

    private func draw(_ frame: FanFrame, in ctx: CGContext) {
        switch frame.type {
        case .defaultFan:
            drawDefaultFan(ctx, frame: frame)
        case .bladeless:
            drawBladeless(ctx, frame: frame)
        }
    }

    // MARK: - 默认四叶风扇

    /// 四片开口 U 形花瓣，端部错位形成风车状中心
    private func drawDefaultFan(_ ctx: CGContext, frame: FanFrame) {
        let trail = min(abs(frame.angularVelocity) * 0.018, 0.35)
        let ghosts = trail > 0.01 ? lineGhostAlphas.count : 0

        ctx.setLineWidth(defaultOutlineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        for layer in stride(from: ghosts, through: 0, by: -1) {
            let progress = ghosts == 0 ? 0 : Double(layer) / Double(ghosts)
            let layerAngle = frame.angle - trail * progress
            let alpha: CGFloat = layer == 0 ? 1 : lineGhostAlphas[layer - 1]

            ctx.saveGState()
            ctx.rotate(by: -CGFloat(layerAngle))
            ctx.setAlpha(alpha)
            for index in 0..<4 {
                ctx.saveGState()
                ctx.rotate(by: CGFloat(index) * .pi / 2)
                ctx.addPath(defaultPetal)
                ctx.strokePath()
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
    }

    // MARK: - 无叶风扇

    private func drawBladeless(_ ctx: CGContext, frame: FanFrame) {
        let r = radius
        let phase = CGFloat(frame.phase)

        // 气流从环顶升起并逐渐消散
        for column in airflowColumns {
            let cycle = (phase + column.offset).truncatingRemainder(dividingBy: 1)
            let y = 0.58 * r + cycle * 0.30 * r
            let height = 0.12 * r * (1.08 - 0.6 * cycle)
            let rect = CGRect(x: (column.x - 0.045) * r, y: y,
                              width: 0.09 * r, height: height)
            ctx.setAlpha(0.15 + 0.85 * (1 - cycle))
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 0.045 * r,
                               cornerHeight: 0.045 * r, transform: nil))
            ctx.fillPath()
        }

        ctx.setAlpha(1)
        ctx.addPath(blowerRing)
        ctx.fillPath(using: .evenOdd)
        ctx.addPath(blowerStand)
        ctx.fillPath()
    }

    // MARK: - 形状

    /// 默认风扇单片花瓣的中心线（归一化到外半径）。
    /// 从参考图形的四片花瓣骨架中提取、旋转对齐后取平均：
    /// 起点是靠近中心的右侧短端，绕过外侧圆瓣，终点是左侧长端，两端不相连。
    private static let defaultPetalPoints: [CGPoint] = [
        CGPoint(x: 0.1200, y: 0.1588),
        CGPoint(x: 0.1678, y: 0.2357),
        CGPoint(x: 0.2229, y: 0.2961),
        CGPoint(x: 0.2742, y: 0.3598),
        CGPoint(x: 0.3177, y: 0.4290),
        CGPoint(x: 0.3534, y: 0.5027),
        CGPoint(x: 0.3776, y: 0.5806),
        CGPoint(x: 0.3806, y: 0.6623),
        CGPoint(x: 0.3848, y: 0.7439),
        CGPoint(x: 0.3614, y: 0.8218),
        CGPoint(x: 0.3172, y: 0.8904),
        CGPoint(x: 0.2551, y: 0.9428),
        CGPoint(x: 0.1795, y: 0.9737),
        CGPoint(x: 0.0986, y: 0.9854),
        CGPoint(x: 0.0170, y: 0.9914),
        CGPoint(x: -0.0647, y: 0.9893),
        CGPoint(x: -0.1461, y: 0.9814),
        CGPoint(x: -0.2268, y: 0.9680),
        CGPoint(x: -0.3045, y: 0.9426),
        CGPoint(x: -0.3718, y: 0.8969),
        CGPoint(x: -0.4172, y: 0.8295),
        CGPoint(x: -0.4319, y: 0.7498),
        CGPoint(x: -0.4032, y: 0.6743),
        CGPoint(x: -0.3510, y: 0.6114),
        CGPoint(x: -0.2974, y: 0.5496),
        CGPoint(x: -0.2453, y: 0.4865),
        CGPoint(x: -0.1955, y: 0.4216),
        CGPoint(x: -0.1507, y: 0.3532),
        CGPoint(x: -0.1102, y: 0.2821),
        CGPoint(x: -0.0763, y: 0.1960),
    ]

    private static func makeDefaultPetal(radius r: CGFloat) -> CGPath {
        smoothOpenPath(defaultPetalPoints.map { CGPoint(x: $0.x * r, y: $0.y * r) })
    }

    /// 用 Catmull-Rom 转三次贝塞尔，画一条穿过所有采样点的平滑开放曲线
    private static func smoothOpenPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            if points.count == 2 { path.addLine(to: points[1]) }
            return path
        }

        for index in 0..<(points.count - 1) {
            let p0 = index == 0 ? points[0] : points[index - 1]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = index + 2 < points.count ? points[index + 2] : points[points.count - 1]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    private static func makeBlowerRing(radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: -0.50 * r, y: -0.53 * r, width: 1.00 * r, height: 1.10 * r))
        path.addEllipse(in: CGRect(x: -0.34 * r, y: -0.37 * r, width: 0.68 * r, height: 0.74 * r))
        return path
    }

    private static func makeBlowerStand(radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addRect(CGRect(x: -0.065 * r, y: -0.82 * r, width: 0.13 * r, height: 0.34 * r))
        let base = CGRect(x: -0.28 * r, y: -0.92 * r, width: 0.56 * r, height: 0.11 * r)
        path.addPath(CGPath(roundedRect: base, cornerWidth: 0.055 * r,
                            cornerHeight: 0.055 * r, transform: nil))
        return path
    }
}
