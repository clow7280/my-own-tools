import AppKit

// MARK: - 设置页

/// 设置页的状态与动作（AppDelegate 装配）
struct SettingsActions {
    var isTrusted: () -> Bool
    var isSnapEnabled: () -> Bool
    var setSnapEnabled: (Bool) -> Void
    var loginItemState: () -> Bool?   // nil = 非 .app 运行，不可用
    var setLoginItem: (Bool) -> Void
    var isDockAutoHideAvailable: () -> Bool
    var isDockAutoHideEnabled: () -> Bool
    var setDockAutoHideEnabled: (Bool) -> Void
    var dockDisplays: () -> [DockAutoHideController.Display]
    var setDockAutoHide: (_ autoHide: Bool, _ displayName: String) -> Void
    var openAXSettings: () -> Void
    var restart: () -> Void
    var quit: () -> Void
}

/// 拖拽分屏 / Dock 自动隐藏 / 开机自启 / 版本与重启退出
final class SettingsPage: FlippedView {
    private(set) var contentHeight: CGFloat = 0

    private let actions: SettingsActions
    private let snapSwitch = NSSwitch()
    private let permissionDot = DotView()
    private let permissionStatus = PageUI.label(size: 11, weight: .medium, color: .tertiaryLabelColor)
    private let permissionButton = NSButton(title: "打开设置", target: nil, action: nil)
    private let dockSwitch = NSSwitch()
    private let dockSubtitle = PageUI.label(size: 10.5, color: .tertiaryLabelColor)
    /// 每块显示器一行，按 builtDisplayNames 的顺序排列，开关的 tag 即下标
    private var displaySwitches: [NSSwitch] = []
    private var displaySubtitles: [NSTextField] = []
    private var builtDisplayNames: [String] = []
    private let loginSwitch = NSSwitch()
    private let loginSubtitle = PageUI.label(size: 10.5, color: .tertiaryLabelColor)

    private static let rowHeight: CGFloat = 44

    init(actions: SettingsActions) {
        self.actions = actions
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 显示器行数随接入的显示器变化，整页重建最简单；常驻控件会随新卡片重新挂载
    private func build() {
        subviews.forEach { $0.removeFromSuperview() }
        displaySwitches = []
        displaySubtitles = []
        builtDisplayNames = actions.dockDisplays().map(\.name)

        var y: CGFloat = 0
        y = buildSnapCard(top: y) + PageUI.cardGap
        y = buildDockCard(top: y) + PageUI.cardGap
        y = buildLoginCard(top: y) + PageUI.cardGap
        y = buildFooter(top: y)
        contentHeight = y
    }

    /// 行：标题 + 说明 + 右侧控件（控件由调用方定位）
    private func addRow(_ title: String, subtitle: String?, y: CGFloat, in card: CardView,
                        titleIndent: CGFloat = 0) -> NSTextField? {
        let name = PageUI.label(title, size: 12.5, weight: .semibold)
        name.frame = NSRect(x: PageUI.cardPadding + titleIndent, y: y + 7,
                            width: PageUI.innerWidth - 90 - titleIndent, height: 16)
        card.addSubview(name)
        guard let subtitle else { return nil }
        let sub = PageUI.label(subtitle, size: 10.5, color: .tertiaryLabelColor)
        sub.frame = NSRect(x: PageUI.cardPadding + titleIndent, y: y + 24,
                           width: PageUI.innerWidth - 90 - titleIndent, height: 13)
        card.addSubview(sub)
        return sub
    }

    private func placeTrailing(_ view: NSView, y: CGFloat, size: NSSize, in card: CardView) {
        view.frame = NSRect(x: PageUI.pageWidth - PageUI.cardPadding - size.width,
                            y: y + (Self.rowHeight - size.height) / 2,
                            width: size.width, height: size.height)
        card.addSubview(view)
    }

    private func buildSnapCard(top: CGFloat) -> CGFloat {
        let card = CardView()
        var y: CGFloat = 2

        _ = addRow("拖拽分屏", subtitle: "Shift 拖动吸附分区、全屏或专注布局", y: y, in: card)
        snapSwitch.controlSize = .small
        snapSwitch.target = self
        snapSwitch.action = #selector(toggleSnap)
        placeTrailing(snapSwitch, y: y, size: snapSwitch.intrinsicContentSize, in: card)
        y += Self.rowHeight
        PageUI.separator(in: card, y: y)

        _ = addRow("辅助功能权限", subtitle: "用于移动、缩放其他 App 的窗口，拖拽分屏必需",
                   y: y, in: card, titleIndent: 15)
        permissionDot.frame = NSRect(x: PageUI.cardPadding, y: y + 12, width: 7, height: 7)
        card.addSubview(permissionDot)
        placeTrailing(permissionStatus, y: y, size: NSSize(width: 60, height: 15), in: card)
        permissionStatus.alignment = .right
        permissionButton.bezelStyle = .rounded
        permissionButton.controlSize = .small
        permissionButton.font = .systemFont(ofSize: 11)
        permissionButton.target = self
        permissionButton.action = #selector(openAX)
        placeTrailing(permissionButton, y: y, size: NSSize(width: 76, height: 22), in: card)
        y += Self.rowHeight

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        return top + y
    }

    private func buildDockCard(top: CGFloat) -> CGFloat {
        let card = CardView()
        var y: CGFloat = 2

        _ = addRow("按显示器隐藏 Dock", subtitle: nil, y: y, in: card)
        dockSubtitle.frame = NSRect(x: PageUI.cardPadding, y: y + 24, width: PageUI.innerWidth - 90, height: 13)
        card.addSubview(dockSubtitle)
        dockSwitch.controlSize = .small
        dockSwitch.target = self
        dockSwitch.action = #selector(toggleDock)
        placeTrailing(dockSwitch, y: y, size: dockSwitch.intrinsicContentSize, in: card)
        y += Self.rowHeight

        for (index, name) in builtDisplayNames.enumerated() {
            PageUI.separator(in: card, y: y)
            let subtitle = addRow(name, subtitle: "", y: y, in: card)!
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.tag = index
            toggle.target = self
            toggle.action = #selector(toggleDisplay(_:))
            placeTrailing(toggle, y: y, size: toggle.intrinsicContentSize, in: card)
            displaySwitches.append(toggle)
            displaySubtitles.append(subtitle)
            y += Self.rowHeight
        }

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        return top + y
    }

    private func buildLoginCard(top: CGFloat) -> CGFloat {
        let card = CardView()
        var y: CGFloat = 2

        loginSubtitle.stringValue = "登录时静默启动，无 Dock 图标"
        _ = addRow("开机自启", subtitle: nil, y: y, in: card)
        loginSubtitle.frame = NSRect(x: PageUI.cardPadding, y: y + 24, width: PageUI.innerWidth - 90, height: 13)
        card.addSubview(loginSubtitle)
        loginSwitch.controlSize = .small
        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin)
        placeTrailing(loginSwitch, y: y, size: loginSwitch.intrinsicContentSize, in: card)
        y += Self.rowHeight

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        return top + y
    }

    private func buildFooter(top: CGFloat) -> CGFloat {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "MyOwnTools"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? AppVersion.short
        let versionLabel = PageUI.label("\(appName) \(version)", size: 10,
                                        mono: true, color: .tertiaryLabelColor)
        versionLabel.frame = NSRect(x: 2, y: top + 6, width: 150, height: 13)
        addSubview(versionLabel)

        let quitButton = NSButton(title: "", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.attributedTitle = NSAttributedString(string: "退出", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.systemRed,
        ])
        quitButton.frame = NSRect(x: PageUI.pageWidth - 62, y: top, width: 62, height: 24)
        addSubview(quitButton)

        let restartButton = NSButton(title: "重启", target: self, action: #selector(restart))
        restartButton.bezelStyle = .rounded
        restartButton.controlSize = .small
        restartButton.font = .systemFont(ofSize: 11)
        restartButton.frame = NSRect(x: PageUI.pageWidth - 62 - 66, y: top, width: 62, height: 24)
        addSubview(restartButton)

        return top + 26
    }

    /// 页面展示时同步当前状态；显示器有增减时先重建，调用方随后按新的 contentHeight 重排弹窗
    func onShow() {
        if actions.dockDisplays().map(\.name) != builtDisplayNames { build() }
        refresh()
    }

    /// 回读各控件的真实状态，开关操作后也走这里，不重建页面以免弹窗高度在展开时跳变
    private func refresh() {
        snapSwitch.state = actions.isSnapEnabled() ? .on : .off

        let trusted = actions.isTrusted()
        permissionDot.color = trusted ? .systemGreen : .systemRed
        permissionStatus.stringValue = "已授权"
        permissionStatus.isHidden = !trusted
        permissionButton.isHidden = trusted

        let login = actions.loginItemState()
        loginSwitch.isEnabled = login != nil
        loginSwitch.state = login == true ? .on : .off
        loginSubtitle.stringValue = login == nil ? "需以 .app 方式运行" : "登录时静默启动，无 Dock 图标"

        let dockAvailable = actions.isDockAutoHideAvailable()
        let dockEnabled = dockAvailable && actions.isDockAutoHideEnabled()
        dockSwitch.isEnabled = dockAvailable
        dockSwitch.state = dockEnabled ? .on : .off
        dockSubtitle.stringValue = dockAvailable ? "按 Dock 所在显示器的设置自动隐藏" : "当前系统不支持"
        // 按名称对应：弹窗开着时插拔显示器不重建，已不在的显示器行保持原样
        let displays = actions.dockDisplays()
        for (index, name) in builtDisplayNames.enumerated() {
            guard let display = displays.first(where: { $0.name == name }) else { continue }
            displaySwitches[index].isEnabled = dockEnabled
            displaySwitches[index].state = display.autoHide ? .on : .off
            displaySubtitles[index].stringValue = (display.isBuiltin ? "内置显示器" : "外接显示器")
                + (display.hostsDock ? " · Dock 所在" : "")
        }
    }

    @objc private func toggleSnap() { actions.setSnapEnabled(snapSwitch.state == .on) }
    @objc private func toggleDock() {
        actions.setDockAutoHideEnabled(dockSwitch.state == .on)
        refresh()
    }
    @objc private func toggleDisplay(_ sender: NSSwitch) {
        guard builtDisplayNames.indices.contains(sender.tag) else { return }
        actions.setDockAutoHide(sender.state == .on, builtDisplayNames[sender.tag])
        refresh()
    }
    @objc private func toggleLogin() {
        actions.setLoginItem(loginSwitch.state == .on)
        refresh()   // 注册可能失败，回读真实状态
    }
    @objc private func openAX() { actions.openAXSettings() }
    @objc private func restart() { actions.restart() }
    @objc private func quit() { actions.quit() }

    /// 权限状态圆点
    private final class DotView: NSView {
        var color: NSColor = .systemGreen { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}
