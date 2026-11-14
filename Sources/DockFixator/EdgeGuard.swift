import Foundation
import CoreGraphics
import ApplicationServices

/// 事件回调必须是 C 函数指针，所以放在文件作用域而不是闭包。
func dockFixatorEventTapCallback(proxy: CGEventTapProxy,
                                 type: CGEventType,
                                 event: CGEvent,
                                 refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let guardEngine = Unmanaged<EdgeGuard>.fromOpaque(refcon).takeUnretainedValue()
    return guardEngine.handle(type: type, event: event)
}

/// 核心防护引擎：在会话层装一个可丢弃事件的 CGEventTap，
/// 把"落在非目标屏 Dock 触发带内的鼠标移动"直接吞掉，
/// 系统因此认为指针从未触碰到那片边缘，Dock 就不会被搬过去。
final class EdgeGuard {

    static let shared = EdgeGuard()

    /// 给程序自己合成的鼠标事件打标记，回调里据此放行，避免自我死锁。
    static let syntheticMarker: Int64 = 0xD0C4A5C4

    struct Configuration {
        var blockingEnabled: Bool = false
        var otherFrames: [CGRect] = []
        var band: CGFloat = 8
        var blockDrags: Bool = false
        var edgeBounce: Bool = true
    }

    private let stateLock = NSLock()
    private var config = Configuration()
    private var relocating = false
    private var blockedTotal = 0
    private var lastLogAt = Date.distantPast

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private init() {}

    // MARK: - 状态

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return tap != nil
    }

    var blockedCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return blockedTotal
    }

    var isRelocating: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return relocating
    }

    func setRelocating(_ value: Bool) {
        stateLock.lock()
        relocating = value
        stateLock.unlock()
    }

    /// 显示器或设置变化时更新拦截参数。
    func updateConfiguration(_ newConfig: Configuration) {
        stateLock.lock()
        config = newConfig
        stateLock.unlock()
    }

    // MARK: - 生命周期

    @discardableResult
    func start() -> Bool {
        stateLock.lock()
        let alreadyRunning = tap != nil
        stateLock.unlock()
        if alreadyRunning { return true }

        let interested: [CGEventType] = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
            .tapDisabledByTimeout,
            .tapDisabledByUserInput
        ]
        var maskValue: UInt64 = 0
        for eventType in interested {
            maskValue |= UInt64(1) << UInt64(eventType.rawValue)
        }
        let mask = CGEventMask(maskValue)

        guard let newTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                             place: .headInsertEventTap,
                                             options: .defaultTap,
                                             eventsOfInterest: mask,
                                             callback: dockFixatorEventTapCallback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }

        stateLock.lock()
        tap = newTap
        runLoopSource = source
        stateLock.unlock()

        CGEvent.tapEnable(tap: newTap, enable: true)
        return true
    }

    func stop() {
        stateLock.lock()
        let runningTap = tap
        let source = runLoopSource
        tap = nil
        runLoopSource = nil
        stateLock.unlock()

        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let runningTap {
            CGEvent.tapEnable(tap: runningTap, enable: false)
        }
    }

    // MARK: - 事件处理

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统在超时或用户输入后会自动禁用 tap，必须立刻重新启用，否则防护静默失效。
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            stateLock.lock()
            let runningTap = tap
            stateLock.unlock()
            if let runningTap {
                CGEvent.tapEnable(tap: runningTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let isDrag = (type == .leftMouseDragged || type == .rightMouseDragged || type == .otherMouseDragged)
        guard type == .mouseMoved || isDrag else { return Unmanaged.passUnretained(event) }

        // 自己合成的事件一律放行。
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker {
            return Unmanaged.passUnretained(event)
        }

        stateLock.lock()
        let snapshot = config
        let isRelocating = relocating
        stateLock.unlock()

        // 迁移 Dock 期间屏蔽真人输入，避免和合成事件互相打架。
        if isRelocating { return nil }

        guard snapshot.blockingEnabled else { return Unmanaged.passUnretained(event) }
        if isDrag && !snapshot.blockDrags { return Unmanaged.passUnretained(event) }

        let location = event.location
        let edge = DockGeometry.currentEdge()
        let zone = snapshot.otherFrames
            .lazy
            .map { DockGeometry.triggerZone(for: $0, edge: edge, band: snapshot.band) }
            .first { $0.contains(location) }

        guard let hitZone = zone else { return Unmanaged.passUnretained(event) }

        stateLock.lock()
        blockedTotal += 1
        let now = Date()
        let shouldLog = now.timeIntervalSince(lastLogAt) > 2
        if shouldLog { lastLogAt = now }
        stateLock.unlock()

        if shouldLog {
            NSLog("[DockFixator] 拦截边缘触发 @ (%.0f, %.0f)", location.x, location.y)
        }

        // 单纯丢弃事件已能阻止 Dock 换屏；再补一次光标"顶出去"作为保险，
        // 让真实光标也不会停在触发带里（拖拽时不干预，避免打断拖放）。
        if snapshot.edgeBounce && !isDrag {
            bounce(location: location, zone: hitZone, edge: edge)
        }

        return nil
    }

    private func bounce(location: CGPoint, zone: CGRect, edge: DockEdge) {
        var pushed = location
        switch edge {
        case .bottom:
            pushed.y = min(location.y, zone.minY - 1)
        case .left:
            pushed.x = min(location.x, zone.maxX + 1)
        case .right:
            pushed.x = max(location.x, zone.minX - 1)
        }

        CGWarpMouseCursorPosition(pushed)

        guard let synthetic = CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState),
                                      mouseType: .mouseMoved,
                                      mouseCursorPosition: pushed,
                                      mouseButton: .left) else { return }
        synthetic.setIntegerValueField(.eventSourceUserData, value: Self.syntheticMarker)
        synthetic.post(tap: .cghidEventTap)
    }
}
