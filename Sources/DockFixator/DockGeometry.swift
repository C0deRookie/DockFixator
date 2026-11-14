import Foundation
import CoreGraphics

/// Dock 贴在屏幕的哪条边。macOS 只允许 bottom / left / right。
enum DockEdge: String {
    case bottom
    case left
    case right
}

/// 纯几何计算：把"某块屏的 Dock 触发带"算成矩形，供事件拦截使用。
enum DockGeometry {

    private static let cacheLock = NSLock()
    private static var cachedEdge: DockEdge = .bottom
    private static var cachedAt = Date.distantPast

    /// 读取 Dock 的停靠边。用户随时可能在系统设置里把 Dock 改到左右两侧，
    /// 所以这里做 1 秒缓存后重新读，不用重启本程序。
    static func currentEdge() -> DockEdge {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if Date().timeIntervalSince(cachedAt) > 1.0 {
            cachedAt = Date()
            let raw = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation")
            cachedEdge = raw.flatMap(DockEdge.init(rawValue:)) ?? .bottom
        }
        return cachedEdge
    }

    /// 某块屏幕上"会让 Dock 跳过来"的区域。
    static func triggerZone(for frame: CGRect, edge: DockEdge, band: CGFloat) -> CGRect {
        let width = min(max(band, 1), 40)
        switch edge {
        case .bottom:
            return CGRect(x: frame.minX, y: frame.maxY - width, width: frame.width, height: width)
        case .left:
            return CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
        case .right:
            return CGRect(x: frame.maxX - width, y: frame.minY, width: width, height: frame.height)
        }
    }

    /// 真正顶到边缘的那个点，用来"骗"Dock 迁移过来。
    static func triggerPoint(in frame: CGRect, edge: DockEdge) -> CGPoint {
        switch edge {
        case .bottom:
            return CGPoint(x: frame.midX, y: frame.maxY - 1)
        case .left:
            return CGPoint(x: frame.minX + 1, y: frame.midY)
        case .right:
            return CGPoint(x: frame.maxX - 1, y: frame.midY)
        }
    }

    /// 距离边缘一段距离的起手点。让合成事件看起来像"从远处滑过去"。
    static func approachPoint(in frame: CGRect, edge: DockEdge, distance: CGFloat) -> CGPoint {
        let offset = max(distance, 20)
        switch edge {
        case .bottom:
            return CGPoint(x: frame.midX, y: frame.maxY - offset)
        case .left:
            return CGPoint(x: frame.minX + offset, y: frame.midY)
        case .right:
            return CGPoint(x: frame.maxX - offset, y: frame.midY)
        }
    }
}
