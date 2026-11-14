import AppKit
import ApplicationServices

/// 菜单栏交互 + 全局调度：装配防护引擎、轮询 Dock 位置、执行自动回位。
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private let settings = Settings.shared
    private let displayCenter = DisplayCenter.shared

    private var statusBarItem: NSStatusItem?
    private var tickTimer: Timer?

    private var lastAutoRestoreAt = Date.distantPast
    private var restoreFailureCount = 0
    private var autoRestoreSuspended = false
    private var launchedAt = Date()

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setUpStatusItem()
        displayCenter.start()

        NotificationCenter.default.addObserver(self,
                                              selector: #selector(handleConfigurationChange),
                                              name: DisplayCenter.didChange,
                                              object: nil)
        NotificationCenter.default.addObserver(self,
                                              selector: #selector(handleConfigurationChange),
                                              name: .dockFixatorSettingsDidChange,
                                              object: nil)

        handleConfigurationChange()
        requestAccessibilityIfNeeded()

        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer

        // 启动时如果 Dock 不在目标屏，等界面稳定后拉回来。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.restoreDockIfNeeded(manual: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
        EdgeGuard.shared.stop()
    }

    // MARK: - 状态栏

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu

        if let button = item.button {
            button.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "DockFixator")
            button.image?.isTemplate = true
            button.toolTip = "DockFixator"
        }

        statusBarItem = item
    }

    private func updateStatusIcon() {
        guard let button = statusBarItem?.button else { return }

        let dockDisplay = DockLocator.dockDisplay(in: displayCenter.displays)
        let anchor = displayCenter.anchorDisplay
        let dockIsAnchored = (dockDisplay?.id == anchor?.id)

        let symbol: String
        let tip: String

        if !Permissions.hasAccessibility {
            symbol = "pin.slash"
            tip = "DockFixator：需要在「隐私与安全性 → 辅助功能」中授权"
        } else if !settings.guardEnabled {
            symbol = "pin.slash"
            tip = "DockFixator：防护已关闭"
        } else if dockIsAnchored, let anchor {
            symbol = "pin.fill"
            tip = "DockFixator：Dock 已锁定在「\(anchor.name)」"
        } else if let dockDisplay, let anchor {
            symbol = "exclamationmark.triangle"
            tip = "DockFixator：Dock 目前在「\(dockDisplay.name)」，目标为「\(anchor.name)」"
        } else {
            symbol = "pin"
            tip = "DockFixator：运行中"
        }

        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.image?.isTemplate = true
        button.toolTip = tip
    }

    // MARK: - 调度

    private func tick() {
        // 每秒对齐一次：既能在用户刚授予辅助功能权限后自动装上 Tap，
        // 也能兜住显示器热插拔、Dock 换边等异步变化。
        handleConfigurationChange()
        updateStatusIcon()

        if Date().timeIntervalSince(launchedAt) > 3 {
            restoreDockIfNeeded(manual: false)
        }
    }

    @objc private func handleConfigurationChange() {
        let anchor = displayCenter.anchorDisplay
        let others = displayCenter.displays
            .filter { $0.id != anchor?.id }
            .map { $0.frame }

        var config = EdgeGuard.Configuration()
        config.blockingEnabled = (anchor != nil) && settings.guardEnabled && Permissions.hasAccessibility
        config.otherFrames = others
        config.band = settings.guardBand
        config.blockDrags = settings.guardDrags
        config.edgeBounce = settings.edgeBounce
        EdgeGuard.shared.updateConfiguration(config)

        if settings.guardEnabled && Permissions.hasAccessibility {
            if !EdgeGuard.shared.isRunning {
                _ = EdgeGuard.shared.start()
            }
        } else if EdgeGuard.shared.isRunning {
            EdgeGuard.shared.stop()
        }

        updateStatusIcon()
    }

    private func requestAccessibilityIfNeeded() {
        guard !Permissions.hasAccessibility else { return }
        Permissions.requestAccessibility()
    }

    // MARK: - 自动回位

    private func restoreDockIfNeeded(manual: Bool) {
        guard let anchor = displayCenter.anchorDisplay else { return }
        guard let dockDisplay = DockLocator.dockDisplay(in: displayCenter.displays) else { return }
        guard dockDisplay.id != anchor.id else {
            restoreFailureCount = 0
            return
        }
        guard Permissions.hasAccessibility else { return }
        guard !DockRelocator.isRunning else { return }

        if !manual {
            guard settings.autoRestore, !autoRestoreSuspended else { return }
            guard Date().timeIntervalSince(lastAutoRestoreAt) > 2.5 else { return }
            // 用户在拖拽时不要抢光标。
            if CGEventSource.buttonState(.combinedSessionState, button: .left) { return }
        }

        lastAutoRestoreAt = Date()
        NSLog("[DockFixator] Dock 位于「\(dockDisplay.name)」，正在拉回「\(anchor.name)」")

        DockRelocator.relocate(to: anchor) { [weak self] started in
            guard let self, started else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                let current = DockLocator.dockDisplay(in: self.displayCenter.displays)
                if current?.id == anchor.id {
                    self.restoreFailureCount = 0
                } else {
                    self.restoreFailureCount += 1
                    if self.restoreFailureCount >= 3 {
                        self.autoRestoreSuspended = true
                        NSLog("[DockFixator] 连续 3 次未能把 Dock 拉回，已暂停自动回位")
                        self.performRestartFallbackIfNeeded()
                    }
                }
            }
        }
    }

    private func performRestartFallbackIfNeeded() {
        guard settings.restartDockFallback, DockProcess.canRestart else { return }
        NSLog("[DockFixator] 触发强力兜底：重启 Dock 进程")
        DockProcess.restart()
    }

    // MARK: - 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        let displays = displayCenter.displays
        let anchor = displayCenter.anchorDisplay
        let dockDisplay = DockLocator.dockDisplay(in: displays)

        // -- 状态摘要
        let statusText: String
        if !Permissions.hasAccessibility {
            statusText = "⚠️ 未授权「辅助功能」，防护未生效"
        } else if !settings.guardEnabled {
            statusText = "防护已关闭"
        } else if let dockDisplay, let anchor, dockDisplay.id != anchor.id {
            statusText = "⚠️ Dock 目前在「\(dockDisplay.name)」"
        } else if let anchor {
            statusText = "✅ Dock 已锁定在「\(anchor.name)」"
        } else {
            statusText = "未检测到显示器"
        }
        menu.addItem(disabledItem(statusText))

        let blocked = EdgeGuard.shared.blockedCount
        if blocked > 0 {
            menu.addItem(disabledItem("累计拦截 \(blocked) 次边缘触发"))
        }
        menu.addItem(.separator())

        // -- 目标显示器
        let anchorMenu = NSMenu()
        for display in displays {
            let title = display.isMain ? "\(display.name)（主显示器）" : display.name
            let item = NSMenuItem(title: title, action: #selector(selectAnchor(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: display.id)
            item.state = (display.id == anchor?.id) ? .on : .off
            anchorMenu.addItem(item)
        }
        let anchorItem = NSMenuItem(title: "把 Dock 固定在", action: nil, keyEquivalent: "")
        anchorItem.submenu = anchorMenu
        menu.addItem(anchorItem)

        // -- 防护带宽
        let bandMenu = NSMenu()
        for value in [4, 6, 8, 10, 12, 16] {
            let item = NSMenuItem(title: "\(value) pt", action: #selector(selectBand(_:)), keyEquivalent: "")
            item.target = self
            item.tag = value
            item.state = (abs(settings.guardBand - CGFloat(value)) < 0.5) ? .on : .off
            bandMenu.addItem(item)
        }
        let bandItem = NSMenuItem(title: "边缘触发宽度", action: nil, keyEquivalent: "")
        bandItem.submenu = bandMenu
        menu.addItem(bandItem)

        menu.addItem(.separator())

        // -- 开关
        menu.addItem(checkItem("启用边缘防护", action: #selector(toggleGuard), on: settings.guardEnabled))
        menu.addItem(checkItem("同时拦截拖拽事件", action: #selector(toggleDrags), on: settings.guardDrags))
        menu.addItem(checkItem("靠边时把光标顶出触发带（更稳）", action: #selector(toggleBounce), on: settings.edgeBounce))

        let autoTitle = autoRestoreSuspended ? "Dock 跑走时自动拉回（已暂停）" : "Dock 跑走时自动拉回"
        menu.addItem(checkItem(autoTitle, action: #selector(toggleAutoRestore), on: settings.autoRestore))
        menu.addItem(checkItem("强力兜底：拉不回时重启 Dock", action: #selector(toggleRestartFallback), on: settings.restartDockFallback))

        menu.addItem(.separator())

        // -- 手动操作
        let restoreItem = NSMenuItem(title: "立即把 Dock 拉回目标屏", action: #selector(restoreNow), keyEquivalent: "r")
        restoreItem.keyEquivalentModifierMask = [.command]
        restoreItem.target = self
        restoreItem.isEnabled = Permissions.hasAccessibility && !DockRelocator.isRunning
        menu.addItem(restoreItem)

        let restartItem = NSMenuItem(title: "重启 Dock 进程", action: #selector(restartDockNow), keyEquivalent: "")
        restartItem.target = self
        restartItem.isEnabled = DockProcess.canRestart
        menu.addItem(restartItem)

        if autoRestoreSuspended {
            let resume = NSMenuItem(title: "恢复自动拉回", action: #selector(resumeAutoRestore), keyEquivalent: "")
            resume.target = self
            menu.addItem(resume)
        }

        menu.addItem(.separator())

        // -- 权限
        let permissionItem = NSMenuItem(title: Permissions.hasAccessibility ? "辅助功能权限：已授权" : "辅助功能权限：未授权（点击前往设置）",
                                        action: Permissions.hasAccessibility ? nil : #selector(openPermissionSettings),
                                        keyEquivalent: "")
        permissionItem.target = self
        permissionItem.isEnabled = !Permissions.hasAccessibility
        menu.addItem(permissionItem)

        menu.addItem(checkItem("登录时自动启动", action: #selector(toggleLoginItem), on: LoginItem.isEnabled))

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 DockFixator", action: #selector(quit), keyEquivalent: "q")
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func checkItem(_ title: String, action: Selector, on: Bool) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    // MARK: - 动作

    @objc private func selectAnchor(_ sender: NSMenuItem) {
        guard let number = sender.representedObject as? NSNumber else { return }
        settings.anchorDisplayID = CGDirectDisplayID(number.uint32Value)

        // 切换目标屏后立刻把 Dock 搬过去。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.restoreDockIfNeeded(manual: true)
        }
    }

    @objc private func selectBand(_ sender: NSMenuItem) {
        settings.guardBand = CGFloat(sender.tag)
    }

    @objc private func toggleGuard() {
        settings.guardEnabled.toggle()
    }

    @objc private func toggleDrags() {
        settings.guardDrags.toggle()
    }

    @objc private func toggleBounce() {
        settings.edgeBounce.toggle()
    }

    @objc private func toggleAutoRestore() {
        autoRestoreSuspended = false
        restoreFailureCount = 0
        settings.autoRestore.toggle()
    }

    @objc private func toggleRestartFallback() {
        settings.restartDockFallback.toggle()
    }

    @objc private func restartDockNow() {
        DockProcess.restart()
    }

    @objc private func resumeAutoRestore() {
        autoRestoreSuspended = false
        restoreFailureCount = 0
    }

    @objc private func restoreNow() {
        restoreFailureCount = 0
        restoreDockIfNeeded(manual: true)
    }

    @objc private func openPermissionSettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func toggleLoginItem() {
        let target = !LoginItem.isEnabled
        do {
            try LoginItem.setEnabled(target)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法设置登录时自动启动"
            alert.informativeText = "请先把 DockFixator.app 拖到「应用程序」文件夹后再试一次。\n\n\(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
