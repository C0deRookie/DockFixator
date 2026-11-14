import Foundation
import ServiceManagement

/// 登录时自动启动。优先用系统登录项（macOS 13+ 的 SMAppService），
/// 如果因为签名/路径问题注册失败，退回到写 LaunchAgent plist 的老办法。
enum LoginItem {

    private static let agentLabel = "com.jansonhe.dockfixator"

    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(agentLabel).plist")
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            return true
        }
        return FileManager.default.fileExists(atPath: agentURL.path)
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            if #available(macOS 13.0, *) {
                do {
                    try SMAppService.mainApp.register()
                    return
                } catch {
                    // 走 LaunchAgent 兜底
                }
            }
            try writeLaunchAgent()
        } else {
            if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            if FileManager.default.fileExists(atPath: agentURL.path) {
                try? FileManager.default.removeItem(at: agentURL)
            }
        }
    }

    private static func writeLaunchAgent() throws {
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: agentURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true,
                                                attributes: nil)
        try data.write(to: agentURL)
    }
}
