import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let snapController = SnapController()
    private var permissionTimer: Timer?

    // 唯一的菜单栏项：系统状态区（网速 + 竖柱 + AI 用量环），点击弹详情窗
    private var statsItem: NSStatusItem?
    private var statsBarView: StatsBarView?
    private var statsPopup: StatsPopupController?
    private let statsMonitor = StatsMonitor()
    private let aiMonitor = AIUsageMonitor()

    /// 登录项注册要求以 .app 形式运行；swift build 的裸二进制不支持
    private var isRunningFromBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LayoutStore.load()
        LayoutStore.startWatching()
        setupStatsItem()

        // 登录项记录的是注册时的应用路径；若 .app 被移动过，
        // 在新位置启动时重新注册一次即可刷新记录
        if isRunningFromBundle, SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.register()
        }

        Permissions.request()
        if Permissions.trusted {
            snapController.start()
        } else {
            // 等待用户在系统设置中完成授权后自动启动
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard let self, Permissions.trusted else { return }
                timer.invalidate()
                self.permissionTimer = nil
                self.snapController.start()
            }
        }
    }

    private func setupStatsItem() {
        let item = NSStatusBar.system.statusItem(withLength: StatsBarView.totalWidth)
        item.autosaveName = "MyOwnTools.SystemStats"
        if let button = item.button {
            let view = StatsBarView(frame: NSRect(x: 0, y: 0,
                                                  width: StatsBarView.totalWidth,
                                                  height: NSStatusBar.system.thickness))
            view.autoresizingMask = [.height]
            button.addSubview(view)
            button.target = self
            button.action = #selector(toggleStatsPopup)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statsBarView = view
        }
        statsItem = item

        statsMonitor.onSample = { [weak self] sample in
            guard let self else { return }
            self.statsBarView?.update(sample)
            self.statsPopup?.update(history: self.statsMonitor.history)
        }
        statsMonitor.start()

        aiMonitor.onUpdate = { [weak self] in
            guard let self else { return }
            self.statsBarView?.updateAIUsage(chatGPT: self.aiMonitor.chatGPT,
                                             claude: self.aiMonitor.claude)
            self.statsPopup?.refreshAI()
        }
        aiMonitor.start()
    }

    @objc private func toggleStatsPopup() {
        guard let button = statsItem?.button else { return }
        if statsPopup == nil {
            statsPopup = StatsPopupController(settingsActions: makeSettingsActions(),
                                              aiProviders: makeAIProviders())
        }
        statsPopup?.toggle(relativeTo: button, history: statsMonitor.history)
    }

    /// AI 页两家提供方的数据源与单家刷新动作
    private func makeAIProviders() -> [AIProviderSpec] {
        [
            AIProviderSpec(kind: .chatGPT, name: "ChatGPT",
                           usage: { [aiMonitor] in aiMonitor.chatGPT },
                           updatedAt: { [aiMonitor] in aiMonitor.chatGPTUpdatedAt },
                           refresh: { [aiMonitor] in aiMonitor.refresh(.chatGPT) }),
            AIProviderSpec(kind: .claude, name: "Claude",
                           usage: { [aiMonitor] in aiMonitor.claude },
                           updatedAt: { [aiMonitor] in aiMonitor.claudeUpdatedAt },
                           refresh: { [aiMonitor] in aiMonitor.refresh(.claude) }),
        ]
    }

    /// 设置页所需的状态与动作
    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            isTrusted: { Permissions.trusted },
            isSnapEnabled: { [weak self] in self?.snapController.isEnabled ?? false },
            setSnapEnabled: { [weak self] in self?.snapController.isEnabled = $0 },
            loginItemState: { [weak self] in
                guard let self, self.isRunningFromBundle else { return nil }
                return SMAppService.mainApp.status == .enabled
            },
            setLoginItem: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("MyOwnTools: 切换开机自启失败：\(error.localizedDescription)")
                }
            },
            aiRefreshInterval: { AIUsageMonitor.interval },
            setAIRefreshInterval: { [aiMonitor] in aiMonitor.setInterval($0) },
            openConfig: {
                LayoutStore.writeDefaultIfMissing()
                LayoutStore.startWatching()     // 目录可能刚创建，补挂监视
                NSWorkspace.shared.open(LayoutStore.configURL)
            },
            openAXSettings: { Permissions.openAccessibilitySettings() },
            lastLayoutLoad: { LayoutStore.lastLoaded },
            restart: { [weak self] in self?.relaunch() },
            quit: { NSApp.terminate(nil) }
        )
    }

    /// 重启：先拉起新实例再退出自身；.app 用 open -n，裸二进制直接再执行一次
    private func relaunch() {
        let process = Process()
        if isRunningFromBundle {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-n", Bundle.main.bundlePath]
        } else if let executable = Bundle.main.executableURL {
            process.executableURL = executable
        } else {
            return
        }
        do {
            try process.run()
        } catch {
            NSLog("MyOwnTools: 重启失败：\(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }
}
