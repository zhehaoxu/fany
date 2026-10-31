//
//  fanyApp.swift
//  fany
//
//  纯状态栏应用：只保留菜单栏图标，不显示 Dock 图标、不打开窗口。
//

import SwiftUI

@main
struct FanyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: FanStatusController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = FanStatusController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
        controller = nil
    }
}
