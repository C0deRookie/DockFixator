import AppKit
import CoreGraphics

/// 一块显示器的几何与身份信息。frame 使用 CoreGraphics 全局坐标（原点在主屏左上角，y 向下），
/// 与 CGEvent.location / CGDisplayBounds 保持一致，避免 Cocoa 坐标系来回翻转出错。
struct DisplayInfo {
    let id: CGDirectDisplayID
    let name: String
    let frame: CGRect
    let isMain: Bool
}

/// 负责枚举当前活动的显示器，并在显示器插拔、分辨率变化时刷新。
final class DisplayCenter {

    static let shared = DisplayCenter()
    static let didChange = Notification.Name("DockFixatorDisplaysDidChange")

    private(set) var displays: [DisplayInfo] = []
    private var callbackRegistered = false
    private var pendingRefresh: DispatchWorkItem?

    /// 目标显示器：用户在菜单里指定优先，否则回落到系统主显示器。
    var anchorDisplay: DisplayInfo? {
        if let id = Settings.shared.anchorDisplayID,
           let matched = displays.first(where: { $0.id == id }) {
            return matched
        }
        return displays.first(where: { $0.isMain }) ?? displays.first
    }

    func start() {
        guard !callbackRegistered else {
            refresh()
            return
        }
        callbackRegistered = true

        CGDisplayRegisterReconfigurationCallback({ _, _, userInfo in
            guard let userInfo else { return }
            let center = Unmanaged<DisplayCenter>.fromOpaque(userInfo).takeUnretainedValue()
            center.scheduleRefresh()
        }, Unmanaged.passUnretained(self).toOpaque())

        refresh()
    }

    /// 显示器重配置回调会被连发多次（begin/end），这里做 0.6 秒防抖。
    func scheduleRefresh() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.refresh()
            }
            self.pendingRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        }
    }

    func refresh() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }

        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return }

        let mainID = CGMainDisplayID()
        let names = screenNames()

        let updated: [DisplayInfo] = ids.prefix(Int(count)).map { id in
            DisplayInfo(id: id,
                        name: names[id] ?? "显示器 \(id)",
                        frame: CGDisplayBounds(id),
                        isMain: id == mainID)
        }

        let signature = updated.map { "\($0.id)@\($0.frame.origin.x),\($0.frame.origin.y),\($0.frame.width)x\($0.frame.height)" }
        let oldSignature = displays.map { "\($0.id)@\($0.frame.origin.x),\($0.frame.origin.y),\($0.frame.width)x\($0.frame.height)" }

        displays = updated

        if signature != oldSignature {
            NotificationCenter.default.post(name: DisplayCenter.didChange, object: nil)
        }
    }

    /// 借 NSScreen.localizedName 拿到系统本地化后的显示器名称（"内建视网膜显示器" 等）。
    private func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
        }
        return names
    }
}
