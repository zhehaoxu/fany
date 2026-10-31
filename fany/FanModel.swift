//
//  FanModel.swift
//  fany
//
//  风扇的档位、类型与应用状态。
//

import Foundation

// MARK: - 档位

enum FanSpeed: Int, CaseIterable {
    case off = 0
    case low
    case medium
    case high

    /// 菜单中显示的档位名称
    var title: String {
        switch self {
        case .off: return "0 档（关闭）"
        case .low: return "1 档（慢速）"
        case .medium: return "2 档（中速）"
        case .high: return "3 档（快速）"
        }
    }

    /// 旋转类风扇的转速（圈/秒）。
    /// 四叶风扇每转 90° 就会重复一次，因此实际观感比这个数值更快。
    var revolutionsPerSecond: Double {
        switch self {
        case .off: return 0
        case .low: return 0.55
        case .medium: return 1.1
        case .high: return 2.0
        }
    }

    /// 旋转类风扇的角速度（弧度/秒）
    var angularVelocity: Double {
        revolutionsPerSecond * 2 * .pi
    }

    /// 非旋转类风扇的动画速度（周期/秒）
    var animationCyclesPerSecond: Double {
        switch self {
        case .off: return 0
        case .low: return 0.5
        case .medium: return 0.9
        case .high: return 1.6
        }
    }
}

// MARK: - 风扇类型

enum FanType: Int, CaseIterable {
    case defaultFan  // 四叶线框风扇（默认）
    case bladeless   // 无叶风扇

    var title: String {
        switch self {
        case .defaultFan: return "默认"
        case .bladeless: return "无叶风扇"
        }
    }

    /// 静止姿态角（顺时针，弧度）。
    /// 四叶风扇静止时为正十字姿态，所以停在 0°。
    var restAngle: Double { 0 }

    /// 旋转图案的对称周期；nil 表示该类型不旋转。
    var symmetry: Double? {
        switch self {
        case .defaultFan: return .pi / 2  // 四叶：每 90° 重复
        case .bladeless: return nil
        }
    }

    var isRotating: Bool { symmetry != nil }
}

// MARK: - 应用状态

/// 只由状态栏控制器读写，没有 SwiftUI 视图观察，因此不需要 ObservableObject。
final class FanState {
    var speed: FanSpeed = .off
    var type: FanType = .defaultFan
    var isOscillating = false

    var isRunning: Bool { speed != .off }
}
