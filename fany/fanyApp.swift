//
//  fanyApp.swift
//  fany
//
//  Created by zhehao.xu on 2026/10/7.
//

import SwiftUI
import AppKit

// MARK: - 风扇档位

enum FanSpeed: Int, CaseIterable {
    case off = 0
    case low
    case medium
    case high

    /// 菜单显示名称
    var menuTitle: String {
        switch self {
        case .off: return "0 档（关闭）"
        case .low: return "1 档（慢速）"
        case .medium: return "2 档（中速）"
        case .high: return "3 档（快速）"
        }
    }

    /// 60Hz 固定时钟下每 tick 推进的帧数（24 帧/圈），数值越大转速越快
    var framesPerTick: Double {
        switch self {
        case .off: return 0 // 0 档不转，仅占位
        case .low: return 1.2    // 约 3 圈/秒
        case .medium: return 1.5 // 约 3.8 圈/秒
        case .high: return 2.4   // 约 6 圈/秒
        }
    }
}

// MARK: - 应用状态
// 仅由 AppDelegate 内部读写，无 SwiftUI 视图观察，无需 ObservableObject

final class AppState {
    var speed: FanSpeed = .off        // 默认 0 档：静止
    var isOscillating = false         // 摇头开关

    var isRunning: Bool { speed != .off }
}

// MARK: - App 入口（纯状态栏应用，无 Dock 图标）

@main
struct fanyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - 状态栏控制器
//
// MenuBarExtra 的 label 不支持逐帧动态更新图像，
// 因此使用 NSStatusItem + Timer 实现帧循环旋转动画。

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let state = AppState()
    private let displayTick: TimeInterval = 1.0 / 60   // 单一 60Hz 统一时钟，同时驱动旋转与摇头
    private var displayTimer: Timer?
    private var frameIndex = 0
    private var framePosition: Double = 0              // 累计帧位置（支持小数步进）
    private var currentFramesPerTick: Double = 0       // 当前实际转速，平滑爬升/下降到档位目标值
    private let rampStep: Double = 0.012               // 加减速斜率：每 tick 转速变化量（约 0.7 帧/tick每秒）
    private var glidingToStop = false                  // 转速归零后的尾段回正滑行中

    // 摇头摆动参数：模拟绕垂直轴“转头”，水平方向透视压缩，扇叶自身不额外旋转
    private let oscillationAmplitude: CGFloat = 40 * .pi / 180  // 最大偏航角 ±40°，对应宽度压缩到 cos(40°)≈0.77
    private let oscillationPeriod: TimeInterval = 4.0           // 一个完整往复周期（放慢至 4 秒）
    private var oscillationPhase: TimeInterval = 0

    /// 脚本生成的帧序列（frame_0 ~ frame_N，数量随脚本自动适配）
    private lazy var frames: [NSImage] = {
        var images: [NSImage] = []
        var index = 0
        while let image = NSImage(named: "frame_\(index)") {
            image.isTemplate = true
            images.append(image)
            index += 1
        }
        if images.isEmpty {
            assertionFailure("未找到 frame_N 图标，请先运行 scripts/generate_fan_icons.swift")
        }
        return images
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "风扇"
        buildMenu()
        updateIcon()
    }

    // MARK: 菜单

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        // 档位：0 档即关闭，1~3 档对应不同转速
        for speed in FanSpeed.allCases {
            let item = makeItem(speed.menuTitle, action: #selector(selectSpeed(_:)), key: "")
            item.tag = speed.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("摇头", action: #selector(toggleOscillation(_:)), key: ""))
        menu.addItem(.separator())
        menu.addItem(makeItem("退出应用", action: #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func makeItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 每次菜单弹出前刷新档位与摇头开关的勾选状态
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(selectSpeed(_:)):
                if let speed = FanSpeed(rawValue: item.tag) {
                    item.state = speed == state.speed ? .on : .off
                }
            case #selector(toggleOscillation(_:)):
                item.state = state.isOscillating ? .on : .off
            default:
                break
            }
        }
    }

    // MARK: 动作

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let speed = FanSpeed(rawValue: sender.tag), speed != state.speed else { return }
        state.speed = speed
        // 切到 0 档时时钟继续运行：实际转速从当前值平滑减速到 0，再滑行回正
        syncTimer()
        sender.state = .on
    }

    @objc private func toggleOscillation(_ sender: NSMenuItem) {
        state.isOscillating.toggle()
        sender.state = state.isOscillating ? .on : .off
        oscillationPhase = 0 // 切换时从回正位置开始
        syncTimer()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: 动画（单一时钟 + 平滑加减速）

    /// 统一时钟在“有运动”时运行：档位>0、减速中或尾段回正滑行中，全部结束后自动停表
    private func syncTimer() {
        let shouldRun = state.speed != .off || currentFramesPerTick > 0 || glidingToStop
        if shouldRun, displayTimer == nil {
            let timer = Timer(timeInterval: displayTick, repeats: true) { [weak self] _ in
                self?.tick()
            }
            timer.tolerance = 0 // 不启用系统时钟合并，保证节奏均匀
            RunLoop.main.add(timer, forMode: .common) // 菜单打开时动画不暂停
            displayTimer = timer
        } else if !shouldRun {
            displayTimer?.invalidate()
            displayTimer = nil
            updateIcon()
        }
    }

    private func tick() {
        guard frames.count > 1 else { return }
        let count = Double(frames.count)
        let target = state.speed.framesPerTick

        // 实际转速线性爬升到目标档位（加速、减速都平滑）
        if currentFramesPerTick < target {
            currentFramesPerTick = min(target, currentFramesPerTick + rampStep)
        } else if currentFramesPerTick > target {
            currentFramesPerTick = max(target, currentFramesPerTick - rampStep)
        }

        if currentFramesPerTick > 0 {
            framePosition += currentFramesPerTick
            framePosition = framePosition.truncatingRemainder(dividingBy: count)
            glidingToStop = false
        } else if state.speed == .off {
            // 转速已归零：缓动滑行到最近的整圈位置（扇叶回正），避免跳帧
            if framePosition > 0.02 {
                glidingToStop = true
                let goal = framePosition > count / 2 ? count : 0
                framePosition += (goal - framePosition) * 0.12
                if abs(goal - framePosition) < 0.02 {
                    framePosition = 0
                    oscillationPhase = 0
                }
            } else {
                // 完全停止：复位并停表
                framePosition = 0
                oscillationPhase = 0
                glidingToStop = false
                displayTimer?.invalidate()
                displayTimer = nil
            }
        }
        frameIndex = Int(framePosition) % frames.count

        if state.isOscillating && state.speed != .off {
            oscillationPhase += displayTick
        }
        updateIcon()
    }

    private func updateIcon() {
        guard !frames.isEmpty else { return }
        let base = frames[frameIndex % frames.count]
        if state.isOscillating && state.speed != .off {
            // 当前偏航角：正弦驱动左右“转头”，用水平压缩模拟绕垂直轴旋转
            let yaw = oscillationAmplitude * sin(2 * .pi * oscillationPhase / oscillationPeriod)
            statusItem.button?.image = swungCopy(of: base, yawRadians: yaw)
        } else {
            statusItem.button?.image = base
        }
    }

    /// 将模板图按偏航角做水平透视压缩后输出新图：
    /// 摇头表现为扇面左右“转头”（宽度随角度收缩/恢复），而非扇叶旋转
    private func swungCopy(of image: NSImage, yawRadians yaw: CGFloat) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        let transform = NSAffineTransform()
        // 转向哪侧，重心略向哪侧偏移，增强“转头”方向感（压缩后两侧各留 ~25% 空间，不会裁切）
        let shift = size.width * 0.15 * sin(yaw)
        transform.translateX(by: size.width / 2 + shift, yBy: size.height / 2)
        transform.scaleX(by: cos(yaw), yBy: 1)   // 绕垂直轴旋转的 2D 投影：水平压缩
        transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
        transform.concat()
        image.draw(at: .zero,
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        result.isTemplate = true
        return result
    }
}
