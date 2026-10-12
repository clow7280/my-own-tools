import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let snapController = SnapController()
    private let layoutEditController = LayoutEditController()
    private var permissionTimer: Timer?
    private var permissionChecks = 0

    /// 授权轮询的节奏。刚启动时用户多半正站在系统设置里勾选，2 秒一轮才能勾完立刻生效；
    /// 30 次约一分钟后基本可以判定用户已经离开，降到 30 秒只为长期待命。
    /// 授权也可能几小时后才发生，所以不设放弃上限。
    private static let permissionFastInterval: TimeInterval = 2
    private static let permissionFastChecks = 30
    private static let permissionSlowInterval: TimeInterval = 30

    // 唯一的菜单栏项：系统状态区（网速 + CPU/GPU/RAM 竖柱），点击弹详情窗
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
        LayoutStore.startWatching()
        setupStatsItem()

        // 登录项记录的是注册时的应用路径；若 .app 被移动过，
        // 在新位置启动时重新注册一次即可刷新记录
        if isRunningFromBundle, SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.register()
        }

        Permissions.request()
        if Permissions.trusted {
            startInteractionControllers()
        } else {
            // 等待用户在系统设置中完成授权后自动启动
            schedulePermissionCheck()
        }
    }

    /// 拖拽吸附与分割线编辑共用授权门槛：全局键鼠监视需要辅助功能权限。
    /// 两者也共用设置页的「拖拽分屏」开关，启动时把持久化的值同步给编辑控制器。
    private func startInteractionControllers() {
        layoutEditController.isEnabled = snapController.isEnabled
        // 编辑模式期间挂起吸附，两个 Shift 手势不会同时生效
        layoutEditController.onEditingChanged = { [weak self] editing in
            self?.snapController.isSuspended = editing
        }
        snapController.start()
        layoutEditController.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPermissionTimer()
        // 编辑控制器持有长按定时器、全局与本地事件监视器和覆盖窗口，退出前一并撤掉
        layoutEditController.stop()
        statsMonitor.stop()
    }

    /// 用一次性定时器逐次重排而不是重复定时器，间隔才能随等待时长变化
    private func schedulePermissionCheck() {
        let interval = permissionChecks < Self.permissionFastChecks
            ? Self.permissionFastInterval
            : Self.permissionSlowInterval
        permissionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.checkPermission() }
        }
    }

    private func checkPermission() {
        guard Permissions.trusted else {
            permissionChecks += 1
            schedulePermissionCheck()
            return
        }
        stopPermissionTimer()
        startInteractionControllers()
    }

    private func stopPermissionTimer() {
        permissionTimer?.invalidate()
        permissionTimer = nil
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
    }

    @objc private func toggleStatsPopup() {
        guard let button = statsItem?.button else { return }
        if statsPopup == nil {
            statsPopup = StatsPopupController(settingsActions: makeSettingsActions())
        }
        statsPopup?.toggle(relativeTo: button, history: statsMonitor.history)
    }

    /// 设置页所需的状态与动作
    private func makeSettingsActions() -> SettingsActions {
        SettingsActions(
            isTrusted: { Permissions.trusted },
            isSnapEnabled: { [weak self] in self?.snapController.isEnabled ?? false },
            // 开关一并管住长按 Shift 编辑：用户关掉分屏后不该还有 Shift 手势拦截
            setSnapEnabled: { [weak self] in
                self?.snapController.isEnabled = $0
                self?.layoutEditController.isEnabled = $0
            },
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
            openAXSettings: { Permissions.openAccessibilitySettings() },
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
