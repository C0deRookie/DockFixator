import AppKit
import ApplicationServices

/// 辅助功能（Accessibility）权限相关的小工具。
/// CGEventTap 要能"丢弃"事件、以及读取 Dock 窗口的 AX 信息，都必须拥有这个权限。
enum Permissions {

    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// 弹出系统授权引导。注意它不会阻塞等待，用户勾选后需要本程序轮询感知。
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
