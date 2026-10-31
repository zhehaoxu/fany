//
//  FanStatusController.swift
//  fany
//
//  状态栏图标、菜单与动画时钟。
//

import AppKit

@MainActor
final class FanStatusController: NSObject {
    private let state = FanState()
    private let renderer = FanIconRenderer()
    private let animator = FanAnimator(type: .defaultFan)

    private var statusItem: NSStatusItem?
    private var updateTimer: Timer?
    private let frameInterval: TimeInterval = 1.0 / 60.0

    private var speedItems: [FanSpeed: NSMenuItem] = [:]
    private var typeItems: [FanType: NSMenuItem] = [:]
    private var oscillationItem: NSMenuItem?

    override init() {
        super.init()
        configureStatusItem()
        buildMenu()
        refreshMenu()
        render()
    }

    func stop() {
        updateTimer?.invalidate()
        updateTimer = nil
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }

    // MARK: - 状态栏图标

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        guard let button = item.button else { return }
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel("风扇")
    }

    // MARK: - 菜单

    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // 档位
        for speed in FanSpeed.allCases {
            let item = NSMenuItem(title: speed.title,
                                  action: #selector(selectSpeed(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = speed.rawValue
            menu.addItem(item)
            speedItems[speed] = item
        }

        menu.addItem(.separator())

        // 摇头
        let oscillate = NSMenuItem(title: "摇头",
                                   action: #selector(toggleOscillation(_:)),
                                   keyEquivalent: "")
        oscillate.target = self
        menu.addItem(oscillate)
        oscillationItem = oscillate

        menu.addItem(.separator())

        // 风扇类型
        let typeHeader = NSMenuItem(title: "风扇类型", action: nil, keyEquivalent: "")
        typeHeader.isEnabled = false
        menu.addItem(typeHeader)

        for type in FanType.allCases {
            let item = NSMenuItem(title: type.title,
                                  action: #selector(selectType(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.tag = type.rawValue
            menu.addItem(item)
            typeItems[type] = item
        }

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "退出 fany", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem?.menu = menu
    }

    private func refreshMenu() {
        for (speed, item) in speedItems {
            item.state = speed == state.speed ? .on : .off
        }
        for (type, item) in typeItems {
            item.state = type == state.type ? .on : .off
        }
        oscillationItem?.state = state.isOscillating ? .on : .off

        let oscillating = state.isOscillating && state.isRunning ? " · 摇头" : ""
        statusItem?.button?.toolTip = "fany · \(state.speed.title)\(oscillating)"
    }

    // MARK: - 动作

    @objc private func selectSpeed(_ sender: NSMenuItem) {
        guard let speed = FanSpeed(rawValue: sender.tag), speed != state.speed else { return }
        state.speed = speed
        refreshMenu()
        startUpdatesIfNeeded()
    }

    @objc private func toggleOscillation(_ sender: NSMenuItem) {
        state.isOscillating.toggle()
        if state.isOscillating {
            animator.resetOscillation()
        }
        refreshMenu()
        startUpdatesIfNeeded()
    }

    @objc private func selectType(_ sender: NSMenuItem) {
        guard let type = FanType(rawValue: sender.tag), type != state.type else { return }
        state.type = type
        animator.prepareForTypeChange(to: type, running: state.isRunning)
        refreshMenu()
        render()
        startUpdatesIfNeeded()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - 动画时钟

    private func startUpdatesIfNeeded() {
        guard updateTimer == nil,
              !animator.isIdle(speed: state.speed, type: state.type) else { return }

        animator.beginUpdates()
        let timer = Timer(timeInterval: frameInterval, repeats: true) { [weak self] _ in
            // Timer 在主 RunLoop 上回调，显式声明主线程隔离
            MainActor.assumeIsolated {
                self?.step()
            }
        }
        timer.tolerance = frameInterval * 0.1   // 允许少量容差，降低唤醒开销
        RunLoop.main.add(timer, forMode: .common) // 菜单展开时动画不暂停
        updateTimer = timer
    }

    private func step() {
        animator.update(speed: state.speed, type: state.type, oscillating: state.isOscillating)
        render()

        if animator.isIdle(speed: state.speed, type: state.type) {
            updateTimer?.invalidate()
            updateTimer = nil
        }
    }

    private func render() {
        guard let button = statusItem?.button else { return }
        button.image = renderer.image(for: animator.frame(for: state.type))
    }
}
