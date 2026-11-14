import AppKit
import Foundation
import CoreGraphics

/// 判断 Dock 此刻"住在"哪块屏幕上。
///
/// 有两点坑：
/// 1. `kCGWindowOwnerName` 是**本地化**的（中文系统里是「程序坞」而不是 "Dock"），
///    所以只能按 Dock 进程的 PID 过滤。
/// 2. Dock 的 AX 窗口列表是空的（Dock 不向第三方暴露 AX 窗口），
///    所以不能像网上一些实现那样读 AXPosition。
///
/// Dock 在主屏上的窗口是一个铺满整块屏幕的 layer=20 窗口，
/// 因此"这块窗口落在哪块屏"就等价于"Dock 在哪块屏"。
enum DockLocator {

    /// Dock 主条固定位于 kCGDockWindowLevel（= 20）这一窗口层级。
    private static let dockWindowLevel = 20

    static func dockPID() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
    }

    /// Dock 窗口矩形（CG 全局坐标）。
    static func dockRect() -> CGRect? {
        guard let pid = dockPID() else { return nil }
        if let rect = pickWindow(pid: pid, visibleOnly: true) { return rect }
        return pickWindow(pid: pid, visibleOnly: false)
    }

    private static func pickWindow(pid: pid_t, visibleOnly: Bool) -> CGRect? {
        let options: CGWindowListOption = visibleOnly
            ? [.optionOnScreenOnly, .excludeDesktopElements]
            : [.optionAll, .excludeDesktopElements]

        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        var best: CGRect?
        var bestScore: CGFloat = -1

        for info in raw {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int, pid_t(ownerPID) == pid else { continue }
            guard (info[kCGWindowLayer as String] as? Int) == dockWindowLevel else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: bounds) else { continue }
            guard rect.width >= 40, rect.height >= 8 else { continue }

            let isOnscreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false
            // 优先取在屏窗口，其次取面积最大的（多空间时会有多份副本）。
            let score = rect.width * rect.height + (isOnscreen ? 1_000_000 : 0)
            if score > bestScore {
                bestScore = score
                best = rect
            }
        }
        return best
    }

    /// Dock 当前所在的显示器。检测不到时返回 nil。
    static func dockDisplay(in displays: [DisplayInfo]) -> DisplayInfo? {
        guard let rect = dockRect(), !displays.isEmpty else { return nil }
        return display(containing: rect, in: displays)
    }

    static func display(containing rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        guard !displays.isEmpty else { return nil }

        // 1) 交叠面积最大者胜出（Dock 窗口铺满整屏，这一步足够准）。
        var best: DisplayInfo?
        var bestArea: CGFloat = 0
        for display in displays {
            let intersection = display.frame.intersection(rect)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        if let best, bestArea > 0 { return best }

        // 2) 兜底：按中心点水平/垂直归属。
        let horizontal = displays.filter { rect.midX >= $0.frame.minX - 1 && rect.midX <= $0.frame.maxX + 1 }
        if let matched = horizontal.min(by: { abs($0.frame.maxY - rect.maxY) < abs($1.frame.maxY - rect.maxY) }) {
            return matched
        }

        // 3) 最后兜底：距离最近的屏。
        return displays.min(by: {
            planeDistance($0.frame, rect) < planeDistance($1.frame, rect)
        })
    }

    private static func planeDistance(_ frame: CGRect, _ rect: CGRect) -> CGFloat {
        let x = max(frame.minX, min(rect.midX, frame.maxX))
        let y = max(frame.minY, min(rect.midY, frame.maxY))
        return hypot(rect.midX - x, rect.midY - y)
    }
}
