import AppKit

// MARK: - 设置页

/// 设置页的状态与动作（AppDelegate 装配）
struct SettingsActions {
    var isTrusted: () -> Bool
    var isSnapEnabled: () -> Bool
    var setSnapEnabled: (Bool) -> Void
    var loginItemState: () -> Bool?   // nil = 非 .app 运行，不可用
    var setLoginItem: (Bool) -> Void
    var openConfig: () -> Void
    var openAXSettings: () -> Void
    var lastLayoutLoad: () -> Date?
    var restart: () -> Void
    var quit: () -> Void
}

/// 拖拽分屏 / 开机自启 / 版本与重启退出
final class SettingsPage: FlippedView {
    private(set) var contentHeight: CGFloat = 0

    private let actions: SettingsActions
    private let snapSwitch = NSSwitch()
    private let configSubtitle = PageUI.label(size: 10.5, color: .tertiaryLabelColor)
    private let permissionDot = DotView()
    private let permissionStatus = PageUI.label(size: 11, weight: .medium, color: .tertiaryLabelColor)
    private let permissionButton = NSButton(title: "打开设置", target: nil, action: nil)
    private let loginSwitch = NSSwitch()
    private let loginSubtitle = PageUI.label(size: 10.5, color: .tertiaryLabelColor)

    private static let rowHeight: CGFloat = 44

    init(actions: SettingsActions) {
        self.actions = actions
        super.init(frame: .zero)

        var y: CGFloat = 0
        y = buildSnapCard(top: y) + PageUI.cardGap
        y = buildLoginCard(top: y) + PageUI.cardGap
        y = buildFooter(top: y)
        contentHeight = y
    }

    required init?(coder: NSCoder) { fatalError() }

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

        _ = addRow("拖拽分屏", subtitle: "Shift 拖动吸附分区，双击标题栏循环布局", y: y, in: card)
        snapSwitch.controlSize = .small
        snapSwitch.target = self
        snapSwitch.action = #selector(toggleSnap)
        placeTrailing(snapSwitch, y: y, size: snapSwitch.intrinsicContentSize, in: card)
        y += Self.rowHeight
        PageUI.separator(in: card, y: y)

        _ = addRow("分屏布局配置", subtitle: nil, y: y, in: card)
        configSubtitle.frame = NSRect(x: PageUI.cardPadding, y: y + 24,
                                      width: PageUI.innerWidth - 90, height: 13)
        card.addSubview(configSubtitle)
        let openButton = NSButton(title: "打开文件", target: self, action: #selector(openConfig))
        openButton.bezelStyle = .rounded
        openButton.controlSize = .small
        openButton.font = .systemFont(ofSize: 11)
        placeTrailing(openButton, y: y, size: NSSize(width: 76, height: 22), in: card)
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

    /// 页面展示时同步当前状态
    func onShow() {
        snapSwitch.state = actions.isSnapEnabled() ? .on : .off

        var configText = "layouts.json · 保存即热重载"
        if let loaded = actions.lastLayoutLoad() {
            configText += " · 上次 " + Self.timeFormatter.string(from: loaded)
        }
        configSubtitle.stringValue = configText

        let trusted = actions.isTrusted()
        permissionDot.color = trusted ? .systemGreen : .systemRed
        permissionStatus.stringValue = "已授权"
        permissionStatus.isHidden = !trusted
        permissionButton.isHidden = trusted

        let login = actions.loginItemState()
        loginSwitch.isEnabled = login != nil
        loginSwitch.state = login == true ? .on : .off
        loginSubtitle.stringValue = login == nil ? "需以 .app 方式运行" : "登录时静默启动，无 Dock 图标"
    }

    @objc private func toggleSnap() { actions.setSnapEnabled(snapSwitch.state == .on) }
    @objc private func toggleLogin() {
        actions.setLoginItem(loginSwitch.state == .on)
        onShow()    // 注册可能失败，回读真实状态
    }
    @objc private func openConfig() {
        actions.openConfig()
        onShow()
    }
    @objc private func openAX() { actions.openAXSettings() }
    @objc private func restart() { actions.restart() }
    @objc private func quit() { actions.quit() }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// 权限状态圆点
    private final class DotView: NSView {
        var color: NSColor = .systemGreen { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
    }
}
