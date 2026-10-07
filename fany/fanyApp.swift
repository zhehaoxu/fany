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
        case .off: return "0档（关闭）"
        case .low: return "一档（慢速）"
        case .medium: return "二档（中速）"
        case .high: return "三档（快速）"
        }
    }

    /// 帧切换间隔（秒），数值越小转速越快；按 24 帧/圈折算角速度
    var frameInterval: TimeInterval {
        switch self {
        case .off: return 0 // 0 档不转，仅占位
        case .low: return 0.12
        case .medium: return 0.06
        case .high: return 0.02
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
    private var animationTimer: Timer?
    private var frameIndex = 0

    // 摇头摆动参数：图标整体以中心为轴左右摆动
    private let oscillationAmplitude: CGFloat = 15 * .pi / 180  // 摆幅 ±15°
    private let oscillationPeriod: TimeInterval = 1.5           // 一个完整往复周期
    private var oscillationTimer: Timer?
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
        if speed == .off {
            // 0 档：停止旋转，回到静止图标
            animationTimer?.invalidate()
            animationTimer = nil
            frameIndex = 0
            updateIcon()
        } else {
            restartAnimation() // 切换档位后立即生效
        }
        sender.state = .on
    }

    @objc private func toggleOscillation(_ sender: NSMenuItem) {
        state.isOscillating.toggle()
        sender.state = state.isOscillating ? .on : .off
        print("摇头开关：\(state.isOscillating ? "开" : "关")")
        if state.isOscillating {
            startOscillation()
        } else {
            stopOscillation()
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: 动画

    private func restartAnimation() {
        animationTimer?.invalidate()
        let interval = state.speed.frameInterval
        animationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self, self.frames.count > 1 else { return }
            self.frameIndex = (self.frameIndex + 1) % self.frames.count
            self.updateIcon()
        }
        animationTimer?.tolerance = 0 // 不启用系统时钟合并，保证逐帧节奏均匀
        RunLoop.main.add(animationTimer!, forMode: .common) // 菜单打开时动画不暂停
    }

    private func updateIcon() {
        guard !frames.isEmpty else { return }
        let base = frames[frameIndex % frames.count]
        if state.isOscillating {
            // 当前摆动角度：正弦驱动，相位由 oscillationTimer 推进
            let angle = oscillationAmplitude * sin(2 * .pi * oscillationPhase / oscillationPeriod)
            statusItem.button?.image = rotatedCopy(of: base, angleRadians: angle)
        } else {
            statusItem.button?.image = base
        }
    }

    // MARK: 摇头动效

    private func startOscillation() {
        oscillationPhase = 0
        oscillationTimer?.invalidate()
        let dt = 1.0 / 30  // 30fps，摆动视觉平滑且开销极小
        oscillationTimer = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.oscillationPhase += dt
            self.updateIcon()
        }
        oscillationTimer?.tolerance = 0
        RunLoop.main.add(oscillationTimer!, forMode: .common)
    }

    private func stopOscillation() {
        oscillationTimer?.invalidate()
        oscillationTimer = nil
        updateIcon() // 图标回正
    }

    /// 将模板图旋转一个小角度后输出新图（正方形画布，内容居中）
    private func rotatedCopy(of image: NSImage, angleRadians angle: CGFloat) -> NSImage {
        let side = max(image.size.width, image.size.height)
        let result = NSImage(size: NSSize(width: side, height: side))
        result.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: side / 2, yBy: side / 2)
        transform.rotate(byRadians: angle)
        transform.translateX(by: -image.size.width / 2, yBy: -image.size.height / 2)
        transform.concat()
        image.draw(at: .zero,
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1)
        result.unlockFocus()
        result.isTemplate = true
        return result
    }
}
