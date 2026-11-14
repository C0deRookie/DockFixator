import Foundation

/// Dock 进程操作。仅用于"强力兜底"：挪不回来时重启 Dock，让它重新落到目标屏上。
enum DockProcess {

    private static let lock = NSLock()
    private static var lastRestartAt = Date.distantPast

    /// 两次重启的最小间隔，避免抖动时反复重启。
    static let cooldown: TimeInterval = 10

    static var canRestart: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(lastRestartAt) > cooldown
    }

    @discardableResult
    static func restart() -> Bool {
        lock.lock()
        let allowed = Date().timeIntervalSince(lastRestartAt) > cooldown
        if allowed { lastRestartAt = Date() }
        lock.unlock()
        guard allowed else { return false }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        task.arguments = ["Dock"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            return true
        } catch {
            return false
        }
    }
}
