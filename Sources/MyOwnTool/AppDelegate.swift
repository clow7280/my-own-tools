import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let snapController = SnapController()
    private var permissionTimer: Timer?

    // 唯一的菜单栏项：系统状态区（网速 + CPU/GPU/RAM 进度条），点击弹详情窗
    private var statsItem: NSStatusItem?
    private var statsBarView: StatsBarView?
    private var statsPopup: StatsPopupController?
    private let statsMonitor = StatsMonitor()

    /// 登录项注册要求以 .app 形式运行；swift build 的裸二进制不支持
    private var isRunningFromBundle: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LayoutStore.load()
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
        item.autosaveName = "MyOwnTool.SystemStats"
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
    }

    @objc private func toggleStatsPopup() {
        guard let button = statsItem?.button else { return }
        if statsPopup == nil {
            statsPopup = StatsPopupController(snapActions: makeSnapActions())
        }
        statsPopup?.toggle(relativeTo: button, history: statsMonitor.history)
    }

    /// 分屏页所需的状态与动作（原菜单栏菜单的全部功能）
    private func makeSnapActions() -> SnapPageActions {
        SnapPageActions(
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
                    NSLog("MyOwnTool: 切换开机自启失败：\(error.localizedDescription)")
                }
            },
            openConfig: {
                LayoutStore.writeDefaultIfMissing()
                NSWorkspace.shared.open(LayoutStore.configURL)
            },
            reloadConfig: { LayoutStore.load() },
            openAXSettings: { Permissions.openAccessibilitySettings() },
            quit: { NSApp.terminate(nil) }
        )
    }
}
