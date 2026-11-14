import AppKit
import Foundation

/// `DockFixator --selftest`：在终端打印当前显示器与 Dock 归属情况，方便排查问题。
enum SelfTest {

    static func run() {
        DisplayCenter.shared.refresh()

        print("=== 显示器 ===")
        for (index, display) in DisplayCenter.shared.displays.enumerated() {
            let flag = display.isMain ? "  ← 主显示器" : ""
            print("[\(index)] \(display.name)\(flag)")
            print("      id=\(display.id)  frame=\(display.frame)")
        }

        print("\n=== Dock ===")
        if let rect = DockLocator.dockRect() {
            print("Dock 窗口: \(rect)")
            let host = DockLocator.dockDisplay(in: DisplayCenter.shared.displays)
            print("Dock 所在屏幕: \(host?.name ?? "未知")")
        } else {
            print("未找到 Dock 窗口（Dock 可能已完全隐藏）")
        }

        print("\n=== 配置 ===")
        print("停靠边: \(DockGeometry.currentEdge().rawValue)")
        print("触发带宽度: \(Int(Settings.shared.guardBand)) pt")
        print("目标屏: \(DisplayCenter.shared.anchorDisplay?.name ?? "未确定")")
        print("辅助功能权限: \(Permissions.hasAccessibility ? "已授权" : "未授权")")
        print("边缘防护: \(Settings.shared.guardEnabled ? "开启" : "关闭")")

        let anchor = DisplayCenter.shared.anchorDisplay
        let others = DisplayCenter.shared.displays.filter { $0.id != anchor?.id }
        print("\n=== 受保护的边缘（这些区域内的鼠标移动会被拦截） ===")
        if others.isEmpty {
            print("没有其它显示器，无需防护")
        } else {
            let edge = DockGeometry.currentEdge()
            for display in others {
                let zone = DockGeometry.triggerZone(for: display.frame,
                                                    edge: edge,
                                                    band: Settings.shared.guardBand)
                print("  \(display.name): \(zone)")
            }
        }
    }
}
