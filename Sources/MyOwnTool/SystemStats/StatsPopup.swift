import AppKit

/// 点击菜单栏状态区弹出的详情窗：系统 / AI / 设置三个选项卡。
/// 仿 Stats：无边框毛玻璃窗挂在菜单栏正下方；宽 348pt 固定，高度随选项卡内容变化。
/// 失焦关闭三重保障：resignKey、全局鼠标按下监视器、应用失活通知——
/// 协作式激活下 accessory 应用的窗口可能始终成不了 key window，只靠 resignKey 不可靠。
@MainActor
final class StatsPopupController: NSObject, NSWindowDelegate {
    private static let width: CGFloat = 348
    private static let padding: CGFloat = 12
    private static let tabHeight: CGFloat = 24
    private static let tabGap: CGFloat = 10

    private let window: PopupWindow
    private let tabs: NSSegmentedControl
    private let systemPage = SystemPage(frame: .zero)
    private let aiPage: AIPage
    private let aiScrollView = NSScrollView(frame: .zero)
    private let settingsPage: SettingsPage
    private var pages: [NSView] { [systemPage, aiScrollView, settingsPage] }

    private var history: [StatsSample] = []
    private var lastClose = Date.distantPast
    private var mouseMonitor: Any?
    /// 打开时记录的锚点：状态项中心 X、菜单栏下缘 Y 与屏幕可见区，切换选项卡改高度时复用
    private var anchor: (midX: CGFloat, top: CGFloat, screen: NSRect?)?

    init(settingsActions: SettingsActions, aiProviders: [AIProviderSpec]) {
        window = PopupWindow(size: NSSize(width: Self.width, height: 200))
        settingsPage = SettingsPage(actions: settingsActions)
        aiPage = AIPage(providers: aiProviders)

        tabs = NSSegmentedControl(labels: ["系统", "AI", "设置"],
                                  trackingMode: .selectOne, target: nil, action: nil)
        super.init()

        window.delegate = self
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.selectedSegment = 0

        aiScrollView.documentView = aiPage
        aiScrollView.drawsBackground = false
        aiScrollView.hasVerticalScroller = true
        aiScrollView.hasHorizontalScroller = false
        aiScrollView.autohidesScrollers = true
        aiScrollView.scrollerStyle = .overlay

        let content = window.contentView!
        content.addSubview(tabs)
        for page in pages {
            page.isHidden = page !== systemPage
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

    /// deinit 不保证运行在主线程，`MainActor.assumeIsolated` 在非主线程会直接 trap；
    /// 监视器 token 取出后与 self 无关，可安全地回到主线程注销。
    deinit {
        guard let token = mouseMonitor else { return }
        if Thread.isMainThread {
            NSEvent.removeMonitor(token)
        } else {
            DispatchQueue.main.async { NSEvent.removeMonitor(token) }
        }
    }

    // MARK: - 显示控制

    /// preferredTab：本次打开要选中的选项卡；nil（如键盘触发取不到点击坐标）保持当前选项卡。
    /// 只在真正打开时生效，关闭与防抖拦截都不改选项卡。
    func toggle(relativeTo button: NSStatusBarButton, history: [StatsSample], preferredTab: Int? = nil) {
        if window.isVisible {
            close()
            return
        }
        // 弹窗开着时点图标：mouseDown 可能先触发失焦关闭，随后 action 到达这里，不应再重开
        guard Date().timeIntervalSince(lastClose) > 0.25 else { return }
        guard let buttonWindow = button.window else { return }

        self.history = history
        anchor = (midX: buttonWindow.frame.midX,
                  top: buttonWindow.frame.minY - 6,
                  screen: buttonWindow.screen?.visibleFrame)
        if let preferredTab, pages.indices.contains(preferredTab), preferredTab != tabs.selectedSegment {
            tabs.selectedSegment = preferredTab
            syncPageVisibility()
        }
        refreshVisiblePage(justShown: true)
        applyLayout()

        NSApp.activate()
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

    /// AI 用量刷新时调用；卡片高度可能变化（模型条数量），AI 页可见时同步重排
    func refreshAI() {
        guard window.isVisible, tabs.selectedSegment == 1 else { return }
        aiPage.update()
        applyLayout()
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
        syncPageVisibility()
        refreshVisiblePage(justShown: true)
        applyLayout()
    }

    /// 只展示当前选项卡对应的页面
    private func syncPageVisibility() {
        for (index, page) in pages.enumerated() {
            page.isHidden = index != tabs.selectedSegment
        }
    }

    // MARK: - 布局

    private var currentPageHeight: CGFloat {
        switch tabs.selectedSegment {
        case 0: return systemPage.contentHeight
        case 1: return min(aiPage.contentHeight, self.maximumAIPageHeight)
        default: return settingsPage.contentHeight
        }
    }

    private var maximumAIPageHeight: CGFloat {
        let chrome = Self.padding * 2 + Self.tabHeight + Self.tabGap
        guard let anchor, let screen = anchor.screen else {
            return max(160, (NSScreen.main?.visibleFrame.height ?? 800) - chrome - 16)
        }
        let availableWindowHeight = max(200, anchor.top - screen.minY - 8)
        return max(160, availableWindowHeight - chrome)
    }

    /// 按当前选项卡内容高度重设窗口尺寸与位置（挂在菜单栏下方、水平对齐状态项）
    private func applyLayout() {
        let pageHeight = currentPageHeight
        let height = Self.padding + Self.tabHeight + Self.tabGap + pageHeight + Self.padding
        window.setContentSize(NSSize(width: Self.width, height: height))

        // contentView 为非翻转坐标：选项卡靠顶，页面在下方
        tabs.frame = NSRect(x: Self.padding, y: height - Self.padding - Self.tabHeight,
                            width: Self.width - Self.padding * 2, height: Self.tabHeight)
        for (index, page) in pages.enumerated() {
            let own: CGFloat
            switch index {
            case 0: own = systemPage.contentHeight
            case 1: own = min(aiPage.contentHeight, self.maximumAIPageHeight)
            default: own = settingsPage.contentHeight
            }
            page.frame = NSRect(x: Self.padding, y: height - Self.padding - Self.tabHeight - Self.tabGap - own,
                                width: Self.width - Self.padding * 2, height: own)
        }
        aiPage.frame = NSRect(
            x: 0,
            y: 0,
            width: Self.width - Self.padding * 2,
            height: aiPage.contentHeight)
        aiScrollView.hasVerticalScroller = aiPage.contentHeight > maximumAIPageHeight

        guard let anchor else { return }
        var origin = NSPoint(x: anchor.midX - Self.width / 2, y: anchor.top - height)
        if let screen = anchor.screen {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - Self.width - 8)
            origin.y = max(origin.y, screen.minY + 8)
        }
        window.setFrameOrigin(origin)
        // 遮罩裁切的半透明窗口改尺寸后需要重算阴影形状
        window.invalidateShadow()
    }

    /// justShown：页面刚展示（打开弹窗/切换选项卡），此时才触发路由/公网 IP 等一次性查询
    private func refreshVisiblePage(justShown: Bool = false) {
        switch tabs.selectedSegment {
        case 0:
            systemPage.update(history)
            if justShown { systemPage.onShow() }
        case 1:
            aiPage.update()
            if justShown {
                aiScrollView.contentView.scroll(to: .zero)
                aiScrollView.reflectScrolledClipView(aiScrollView.contentView)
            }
        case 2:
            if justShown { settingsPage.onShow() }
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
        // 圆角用 maskImage 裁切：layer cornerRadius 只裁内容层，
        // 毛玻璃底衬会在四角露出白边
        effect.maskImage = Self.roundedMask(radius: 14)
        contentView = effect
    }

    /// 可拉伸的圆角遮罩（capInsets 保证窗口改高度时圆角不变形）
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    override var canBecomeKey: Bool { true }

    // ESC 关闭
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
