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
    case low = 1
    case medium
    case high

    /// 菜单显示名称
    var menuTitle: String {
        switch self {
        case .low: return "一档（慢速）"
        case .medium: return "二档（中速）"
        case .high: return "三档（快速）"
        }
    }

    /// 帧切换间隔（秒），数值越小转速越快；按 24 帧/圈折算角速度
    var frameInterval: TimeInterval {
        switch self {
        case .low: return 0.12
        case .medium: return 0.06
        case .high: return 0.02
        }
    }
}

// MARK: - 应用状态
// 仅由 AppDelegate 内部读写，无 SwiftUI 视图观察，无需 ObservableObject

final class AppState {
    var isRunning = false
    var speed: FanSpeed = .low
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

        menu.addItem(makeItem("开启", action: #selector(startFan), key: ""))
        menu.addItem(makeItem("关闭", action: #selector(stopFan), key: ""))
        menu.addItem(.separator())

        for speed in FanSpeed.allCases {
            let item = makeItem(speed.menuTitle, action: #selector(selectSpeed(_:)), key: "")
            item.tag = speed.rawValue
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("退出应用", action: #selector(quit), key: "q"))

        statusItem.menu = menu
    }

    private func makeItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    /// 每次菜单弹出前刷新可用状态与档位勾选
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            switch item.action {
            case #selector(startFan):
                item.isEnabled = !state.isRunning
            case #selector(stopFan):
                item.isEnabled = state.isRunning
            case #selector(selectSpeed(_:)):
                if let speed = FanSpeed(rawValue: item.tag) {
                    item.state = speed == state.speed ? .on : .off
                }
            default:
                break
            }
        }
    }

    // MARK: 动作

    @objc private func startFan() {
        guard !state.isRunning else { return }
        state.isRunning = true
        restartAnimation()
    }

    @objc private func stopFan() {
        state.isRunning = false
        animationTimer?.invalidate()
        animationTimer = nil
        frameIndex = 0
        updateIcon() // 回到静止图标
    }

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let speed = FanSpeed(rawValue: sender.tag) else { return }
        state.speed = speed
        if state.isRunning {
            restartAnimation() // 切换档位后立即生效
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
        statusItem.button?.image = frames[frameIndex % frames.count]
    }
}
