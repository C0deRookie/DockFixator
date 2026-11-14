import Foundation
import CoreGraphics

/// 「主动迁移」：模拟一次从远处滑到目标屏底边的动作，把 Dock 拽回目标屏。
/// 系统判断 Dock 归属依赖指针事件流，所以既要 warp 光标，也要伪造 mouseMoved。
enum DockRelocator {

    private static let lock = NSLock()
    private static var running = false

    /// 是否正在迁移。
    static var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    static func relocate(to anchor: DisplayInfo, completion: ((Bool) -> Void)? = nil) {
        lock.lock()
        if running {
            lock.unlock()
            completion?(false)
            return
        }
        running = true
        lock.unlock()

        let edge = DockGeometry.currentEdge()
        let savedCursor = CGEvent(source: nil)?.location ?? .zero
        let target = DockGeometry.triggerPoint(in: anchor.frame, edge: edge)
        let approach = DockGeometry.approachPoint(in: anchor.frame, edge: edge, distance: 60)
        let source = CGEventSource(stateID: .hidSystemState)

        DispatchQueue.global(qos: .userInitiated).async {
            EdgeGuard.shared.setRelocating(true)

            post(to: approach, source: source)
            Thread.sleep(forTimeInterval: 0.03)

            // 分步逼近，模拟真实滑行动作。
            let steps = 8
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                let point = CGPoint(x: approach.x + (target.x - approach.x) * t,
                                    y: approach.y + (target.y - approach.y) * t)
                post(to: point, source: source)
                Thread.sleep(forTimeInterval: 0.012)
            }

            // 在边缘点上反复"蹭"几下，确保事件流足够明确。
            for _ in 0..<8 {
                post(to: target, source: source)
                Thread.sleep(forTimeInterval: 0.02)
            }

            CGWarpMouseCursorPosition(savedCursor)
            EdgeGuard.shared.setRelocating(false)

            lock.lock()
            running = false
            lock.unlock()

            DispatchQueue.main.async {
                completion?(true)
            }
        }
    }

    private static func post(to point: CGPoint, source: CGEventSource?) {
        CGWarpMouseCursorPosition(point)
        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: .mouseMoved,
                                  mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        event.setIntegerValueField(.eventSourceUserData, value: EdgeGuard.syntheticMarker)
        event.post(tap: .cghidEventTap)
    }
}
