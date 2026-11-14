import Foundation
import CoreGraphics

extension Notification.Name {
    /// 任一配置发生变化时广播，防护引擎和菜单都监听它做增量刷新。
    static let dockFixatorSettingsDidChange = Notification.Name("DockFixatorSettingsDidChange")
}

/// 集中管理所有持久化配置，避免多处各自读写 UserDefaults 造成状态不同步。
final class Settings {

    static let shared = Settings()

    private enum Key {
        static let anchorDisplayID = "anchorDisplayID"
        static let guardEnabled = "guardEnabled"
        static let guardBand = "guardBand"
        static let guardDrags = "guardDrags"
        static let edgeBounce = "edgeBounce"
        static let autoRestore = "autoRestore"
        static let restartDockFallback = "restartDockFallback"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Key.guardEnabled: true,
            Key.guardBand: 8.0,
            Key.guardDrags: false,
            Key.edgeBounce: true,
            Key.autoRestore: true,
            Key.restartDockFallback: false
        ])
    }

    /// Dock 要固定的目标显示器。nil 表示跟随系统主显示器（菜单栏所在那块）。
    var anchorDisplayID: CGDirectDisplayID? {
        get {
            let raw = defaults.integer(forKey: Key.anchorDisplayID)
            return raw > 0 ? CGDirectDisplayID(raw) : nil
        }
        set {
            if let newValue {
                defaults.set(Int(newValue), forKey: Key.anchorDisplayID)
            } else {
                defaults.removeObject(forKey: Key.anchorDisplayID)
            }
            notifyChange()
        }
    }

    /// 是否启用边缘防护（总开关）。
    var guardEnabled: Bool {
        get { defaults.bool(forKey: Key.guardEnabled) }
        set {
            defaults.set(newValue, forKey: Key.guardEnabled)
            notifyChange()
        }
    }

    /// 触发带宽度（点）。默认 8：屏幕最外侧 8pt 内的鼠标移动会被丢弃。
    var guardBand: CGFloat {
        get {
            let value = defaults.double(forKey: Key.guardBand)
            return CGFloat(min(max(value, 2.0), 24.0))
        }
        set {
            defaults.set(Double(min(max(newValue, 2.0), 24.0)), forKey: Key.guardBand)
            notifyChange()
        }
    }

    /// 是否连拖拽事件一起拦截（默认关闭，拖拽到边缘一般不会导致 Dock 换屏）。
    var guardDrags: Bool {
        get { defaults.bool(forKey: Key.guardDrags) }
        set {
            defaults.set(newValue, forKey: Key.guardDrags)
            notifyChange()
        }
    }

    /// 是否把真实光标从触发带里"顶"出来。开启后更稳，代价是靠边时指针会轻微回弹。
    var edgeBounce: Bool {
        get { defaults.bool(forKey: Key.edgeBounce) }
        set {
            defaults.set(newValue, forKey: Key.edgeBounce)
            notifyChange()
        }
    }

    /// Dock 意外跑到非目标屏时，是否自动把它"拉"回来。
    var autoRestore: Bool {
        get { defaults.bool(forKey: Key.autoRestore) }
        set {
            defaults.set(newValue, forKey: Key.autoRestore)
            notifyChange()
        }
    }

    /// 强力兜底：合成事件挪不动 Dock 时，直接重启 Dock 进程（会闪一下，1~2 秒）。
    var restartDockFallback: Bool {
        get { defaults.bool(forKey: Key.restartDockFallback) }
        set {
            defaults.set(newValue, forKey: Key.restartDockFallback)
            notifyChange()
        }
    }

    private func notifyChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .dockFixatorSettingsDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .dockFixatorSettingsDidChange, object: nil)
            }
        }
    }
}
