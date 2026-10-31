//
//  FanAnimator.swift
//  fany
//
//  风扇动画状态机：平滑加减速、停止回正、摇头与动画相位。
//  与 AppKit 无关，只负责时间推进。
//

import Foundation
import QuartzCore

final class FanAnimator {
    /// 当前旋转角（顺时针，弧度）
    private(set) var angle: Double
    /// 当前角速度（弧度/秒），用于驱动动态模糊
    private(set) var angularVelocity: Double = 0
    /// 摇头偏航角（弧度），正值向右转
    private(set) var yaw: Double = 0
    /// 非旋转类风扇的动画进度（0...1）
    private(set) var phase: Double = 0

    private var oscillationTime: Double = 0
    private var isSettling = false
    private var lastTimestamp: CFTimeInterval?
    private let now: () -> CFTimeInterval

    /// 摇头参数：±36°、4 秒一个完整来回
    private let oscillationAmplitude = 36.0 * Double.pi / 180
    private let oscillationPeriod = 4.0
    /// 转速低于该值后不再继续惯性旋转，直接回正
    private let stopThreshold = 0.6

    /// 时钟可注入，便于用固定步长测试动画曲线
    init(type: FanType, now: @escaping () -> CFTimeInterval = CACurrentMediaTime) {
        angle = type.restAngle
        self.now = now
    }

    // MARK: - 生命周期

    /// 每次启动计时器时调用，丢弃两帧之间的空档，避免跳帧
    func beginUpdates() {
        lastTimestamp = nil
    }

    /// 重新开启摇头时，从中间位置开始摆动
    func resetOscillation() {
        oscillationTime = 0
    }

    /// 切换风扇类型；静止时直接回到新类型的静止姿态
    func prepareForTypeChange(to type: FanType, running: Bool) {
        isSettling = false
        if !running {
            angle = type.restAngle
            angularVelocity = 0
            phase = 0
            yaw = 0
            oscillationTime = 0
        }
        lastTimestamp = nil
    }

    // MARK: - 每帧推进

    func update(speed: FanSpeed, type: FanType, oscillating: Bool) {
        let now = self.now()
        guard let last = lastTimestamp else {
            lastTimestamp = now
            return
        }
        lastTimestamp = now

        // 睡眠唤醒或主线程卡顿时，限制单帧步长，避免画面突跳
        let dt = min(max(now - last, 0), 0.05)
        guard dt > 0 else { return }

        if type.isRotating {
            updateRotation(dt: dt, speed: speed, type: type)
        } else {
            angularVelocity = 0
            updatePhase(dt: dt, speed: speed)
        }
        updateOscillation(dt: dt, active: oscillating && speed != .off)
    }

    func frame(for type: FanType) -> FanFrame {
        FanFrame(type: type,
                 angle: angle,
                 yaw: yaw,
                 phase: phase,
                 angularVelocity: angularVelocity)
    }

    /// 动画是否已完全静止（可停止计时器）
    func isIdle(speed: FanSpeed, type: FanType) -> Bool {
        guard speed == .off else { return false }
        if type.isRotating {
            return angularVelocity == 0 && !isSettling && yaw == 0
        }
        return phase == 0 && yaw == 0
    }

    // MARK: - 旋转

    private func updateRotation(dt: Double, speed: FanSpeed, type: FanType) {
        let target = speed.angularVelocity

        if target > 0 {
            isSettling = false
            // 指数逼近目标转速，起步和换档都不会突兀
            angularVelocity += (target - angularVelocity) * (1 - exp(-dt / 0.24))
            angle += angularVelocity * dt
        } else {
            // 关闭后靠“摩擦”减速
            angularVelocity *= exp(-dt / 0.30)
            if angularVelocity < stopThreshold {
                // 慢到几乎看不出转动时，缓动到最近的对称静止角
                angularVelocity = 0
                isSettling = true
                if let symmetry = type.symmetry {
                    let turns = ((angle - type.restAngle) / symmetry).rounded()
                    let goal = type.restAngle + turns * symmetry
                    let delta = goal - angle
                    angle += delta * (1 - exp(-dt / 0.09))
                    if abs(delta) < 0.002 {
                        angle = goal
                        isSettling = false
                    }
                }
            } else {
                angle += angularVelocity * dt
            }
        }

        angle = angle.truncatingRemainder(dividingBy: 2 * .pi)
    }

    // MARK: - 非旋转动画

    private func updatePhase(dt: Double, speed: FanSpeed) {
        if speed != .off {
            phase += dt * speed.animationCyclesPerSecond
            phase = phase.truncatingRemainder(dividingBy: 1)
            if phase < 0 { phase += 1 }
        } else if phase > 0 {
            // 关闭时把当前这一轮气流播放完，再停在起点
            phase += (1 - phase) * (1 - exp(-dt / 0.10))
            if phase > 0.995 { phase = 0 }
        }
    }

    // MARK: - 摇头

    private func updateOscillation(dt: Double, active: Bool) {
        if active {
            oscillationTime += dt
            let target = oscillationAmplitude * sin(2 * .pi * oscillationTime / oscillationPeriod)
            yaw += (target - yaw) * (1 - exp(-dt / 0.12))
        } else if yaw != 0 {
            yaw *= exp(-dt / 0.12)
            if abs(yaw) < 0.0005 { yaw = 0 }
        }
    }
}
