import AppKit

/// 点击菜单栏状态区弹出的详情窗：占用 / 温度 / 网络 / AI（预留）/ 分屏 五个选项卡。
/// 仿 Stats：无边框毛玻璃窗挂在菜单栏正下方。
/// 失焦关闭三重保障：resignKey、全局鼠标按下监视器、应用失活通知——
/// macOS 14+ 协作式激活下 accessory 应用的窗口可能始终成不了 key window，只靠 resignKey 不可靠。
final class StatsPopupController: NSObject, NSWindowDelegate {
    private static let size = NSSize(width: 300, height: 340)

    private let window: PopupWindow
    private let tabs: NSSegmentedControl
    private let usagePage = UsagePage()
    private let tempPage = TempPage()
    private let netPage = NetworkPage()
    private let snapPage: SnapPage
    private let pages: [NSView]

    private var history: [StatsSample] = []
    private var lastClose = Date.distantPast
    private var mouseMonitor: Any?

    init(snapActions: SnapPageActions) {
        window = PopupWindow(size: Self.size)
        snapPage = SnapPage(actions: snapActions)

        let aiPage = FlippedView(frame: .zero)
        let placeholder = NSTextField(labelWithString: "Codex / Claude 订阅用量\n预留位，待接入")
        placeholder.font = .systemFont(ofSize: 12)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.maximumNumberOfLines = 2
        placeholder.frame = NSRect(x: 16, y: 120, width: Self.size.width - 32, height: 40)
        aiPage.addSubview(placeholder)

        pages = [usagePage, tempPage, netPage, aiPage, snapPage]
        tabs = NSSegmentedControl(labels: ["占用", "温度", "网络", "AI", "分屏"],
                                  trackingMode: .selectOne, target: nil, action: nil)
        super.init()

        window.delegate = self
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0
        tabs.frame = NSRect(x: 12, y: Self.size.height - 36, width: Self.size.width - 24, height: 24)

        let content = window.contentView!
        content.addSubview(tabs)
        let pageFrame = NSRect(x: 0, y: 0, width: Self.size.width, height: Self.size.height - 44)
        for page in pages {
            page.frame = pageFrame
            page.isHidden = page !== usagePage
            content.addSubview(page)
        }

        NotificationCenter.default.addObserver(self, selector: #selector(appResignedActive),
                                               name: NSApplication.didResignActiveNotification, object: nil)
        // 本应用可能从未成为活跃应用（协作式激活可拒绝），resignActive/resignKey 均不可靠；
        // 「其他应用被激活」不依赖自身状态，可兜住 Cmd-Tab、Spotlight 等无鼠标点击的失焦
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(otherAppActivated(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
    }

    deinit {
        removeMouseMonitor()
    }

    // MARK: - 显示控制

    func toggle(relativeTo button: NSStatusBarButton, history: [StatsSample]) {
        if window.isVisible {
            close()
            return
        }
        // 弹窗开着时点图标：mouseDown 可能先触发失焦关闭，随后 action 到达这里，不应再重开
        guard Date().timeIntervalSince(lastClose) > 0.25 else { return }
        guard let buttonWindow = button.window else { return }

        self.history = history
        refreshVisiblePage(justShown: true)

        // 水平居中对齐图标、挂在菜单栏下方，并收拢进屏幕可见范围
        var origin = NSPoint(x: buttonWindow.frame.midX - Self.size.width / 2,
                             y: buttonWindow.frame.minY - Self.size.height - 6)
        if let screen = buttonWindow.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - Self.size.width - 8)
        }
        window.setFrameOrigin(origin)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)

        // 点到本应用窗口之外（含其他应用、桌面、别的菜单栏项）一律关闭。
        // 这是最可靠的一条关闭路径：与分屏共用的全局监视器机制，已有辅助功能授权
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.close()
        }
    }

    func update(history: [StatsSample]) {
        self.history = history
        guard window.isVisible else { return }
        refreshVisiblePage()
    }

    private func close() {
        guard window.isVisible else { return }
        window.orderOut(nil)
        lastClose = Date()
        removeMouseMonitor()
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    @objc private func appResignedActive() {
        close()
    }

    @objc private func otherAppActivated(_ notification: Notification) {
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        if let app, app.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
        close()
    }

    @objc private func tabChanged() {
        for (index, page) in pages.enumerated() {
            page.isHidden = index != tabs.selectedSegment
        }
        refreshVisiblePage(justShown: true)
    }

    /// justShown：页面刚展示（打开弹窗/切换选项卡），此时才触发路由/公网 IP 等一次性查询
    private func refreshVisiblePage(justShown: Bool = false) {
        switch tabs.selectedSegment {
        case 0: usagePage.update(history)
        case 1: tempPage.update(history)
        case 2:
            netPage.update(history)
            if justShown { netPage.onShow() }
        case 4:
            if justShown { snapPage.onShow() }
        default: break
        }
    }
}

// MARK: - 窗口

/// 无边框、可成为 key window 的毛玻璃弹窗
private final class PopupWindow: NSWindow {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.moveToActiveSpace, .ignoresCycle]
        isReleasedWhenClosed = false

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        contentView = effect
    }

    override var canBecomeKey: Bool { true }

    // ESC 关闭
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
