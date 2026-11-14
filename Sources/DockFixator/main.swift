import AppKit
import Foundation

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

// 诊断模式：打印显示器与 Dock 归属后直接退出，不会弹权限框。
if CommandLine.arguments.contains("--selftest") {
    SelfTest.run()
    exit(0)
}

let appDelegate = AppDelegate()
application.delegate = appDelegate
application.run()
