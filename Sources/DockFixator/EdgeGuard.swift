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
    }

    private let stateLock = NSLock()
    private var config = Configuration()
    private var relocating = false
    private var relocatingSince = Date.distantPast
    private var blockedTotal = 0
    private var lastLogAt = Date.distantPast
    private var lastRealInputAt = Date.distantPast

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
        if value { relocatingSince = Date() }
        stateLock.unlock()
    }

    /// 距离上一次"真人"鼠标移动过了多久。自动归位要靠它避开用户正在操作的时候。
    var secondsSinceRealInput: TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Date().timeIntervalSince(lastRealInputAt)
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
        let relocatingFor = Date().timeIntervalSince(relocatingSince)
        lastRealInputAt = Date()
        stateLock.unlock()

        // 迁移 Dock 期间屏蔽真人输入，避免和合成事件互相打架。
        if isRelocating {
            // 保险丝：迁移流程一旦异常没复位（正常只要 0.4 秒），
            // 超过 2 秒就强制解除，绝不留下"永久吞掉鼠标移动"的状态。
            if relocatingFor > 2.0 {
                stateLock.lock()
                relocating = false
                stateLock.unlock()
            } else {
                return nil
            }
        }

        guard snapshot.blockingEnabled else { return Unmanaged.passUnretained(event) }
        if isDrag && !snapshot.blockDrags { return Unmanaged.passUnretained(event) }

        let location = event.location
        let edge = DockGeometry.currentEdge()
        let zone = snapshot.otherFrames
            .lazy
            .map { DockGeometry.triggerZone(for: $0, edge: edge, band: snapshot.band) }
            .first { $0.contains(location) }

        guard zone != nil else { return Unmanaged.passUnretained(event) }

        stateLock.lock()
        blockedTotal += 1
        let now = Date()
        let shouldLog = now.timeIntervalSince(lastLogAt) > 2
        if shouldLog { lastLogAt = now }
        stateLock.unlock()

        if shouldLog {
            NSLog("[DockFixator] 拦截边缘触发 @ (%.0f, %.0f)", location.x, location.y)
        }

        // 只丢弃事件，绝不挪动光标。
        //
        // 早期版本在这里额外用 CGWarpMouseCursorPosition 把光标"顶出"触发带，
        // 结果在双屏接缝处把指针卡死了：指针每次往边缘走都被推回去，物理位移
        // 和虚拟光标位置的差值越拉越大，必须猛甩一次才能跳出去。
        // 拦截本身不需要碰光标——事件流丢掉就够了，光标该怎么动还是怎么动。
        return nil
    }
}
