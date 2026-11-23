import AppKit
import StatsCore

// MARK: - 设置页

/// 设置页的状态与动作（AppDelegate 装配）
struct SettingsActions {
    var isTrusted: () -> Bool
    var isSnapEnabled: () -> Bool
    var setSnapEnabled: (Bool) -> Void
    var loginItemState: () -> Bool?   // nil = 非 .app 运行，不可用
    var setLoginItem: (Bool) -> Void
    var keepAwake: KeepAwakeController
    var isDockAutoHideAvailable: () -> Bool
    var isDockAutoHideEnabled: () -> Bool
    var setDockAutoHideEnabled: (Bool) -> Void
    var dockDisplays: () -> [DockAutoHideController.Display]
    var setDockAutoHide: (_ autoHide: Bool, _ displayName: String) -> Void
    var openAXSettings: () -> Void
    var restart: () -> Void
    var quit: () -> Void
}

/// 保持唤醒 / 拖拽分屏 / Dock 自动隐藏 / 开机自启 / 版本与重启退出
final class SettingsPage: FlippedView {
    private(set) var contentHeight: CGFloat = 0

    private let actions: SettingsActions
    private let awakeSwitch = NSSwitch()
    private let awakeSubtitle = PageUI.label(size: 10.5, color: .tertiaryLabelColor)
    private let lidSwitch = NSSwitch()
    private let lidSubtitle = PageUI.label(size: 10.5, color: .tertiaryLabelColor)
    private let durationPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let batteryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
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
        y = buildKeepAwakeCard(top: y) + PageUI.cardGap
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

    /// 弹出菜单统一为小号控件，宽度与开关行的控件一样贴右
    private static let popupSize = NSSize(width: 92, height: 22)

    private func buildKeepAwakeCard(top: CGFloat) -> CGFloat {
        let card = CardView()
        var y: CGFloat = 2

        _ = addRow("保持唤醒", subtitle: nil, y: y, in: card)
        awakeSubtitle.frame = NSRect(x: PageUI.cardPadding, y: y + 24, width: PageUI.innerWidth - 90, height: 13)
        card.addSubview(awakeSubtitle)
        awakeSwitch.controlSize = .small
        awakeSwitch.target = self
        awakeSwitch.action = #selector(toggleAwake)
        placeTrailing(awakeSwitch, y: y, size: awakeSwitch.intrinsicContentSize, in: card)
        y += Self.rowHeight
        PageUI.separator(in: card, y: y)

        _ = addRow("合盖时不休眠", subtitle: nil, y: y, in: card)
        lidSubtitle.frame = NSRect(x: PageUI.cardPadding, y: y + 24, width: PageUI.innerWidth - 90, height: 13)
        card.addSubview(lidSubtitle)
        lidSwitch.controlSize = .small
        lidSwitch.target = self
        lidSwitch.action = #selector(toggleLid)
        placeTrailing(lidSwitch, y: y, size: lidSwitch.intrinsicContentSize, in: card)
        y += Self.rowHeight
        PageUI.separator(in: card, y: y)

        _ = addRow("定时关闭", subtitle: "每次开启默认不限时", y: y, in: card)
        configurePopup(durationPopup, titles: KeepAwakePolicy.durations.map(Self.durationTitle),
                       action: #selector(pickDuration))
        placeTrailing(durationPopup, y: y, size: Self.popupSize, in: card)
        y += Self.rowHeight
        PageUI.separator(in: card, y: y)

        _ = addRow("低电量时关闭", subtitle: "使用电池且电量低于该值时关闭", y: y, in: card)
        configurePopup(batteryPopup, titles: KeepAwakePolicy.batteryThresholds.map { $0.map { "\($0)%" } ?? "不启用" },
                       action: #selector(pickBattery))
        placeTrailing(batteryPopup, y: y, size: Self.popupSize, in: card)
        y += Self.rowHeight

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        return top + y
    }

    private func configurePopup(_ popup: NSPopUpButton, titles: [String], action: Selector) {
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.controlSize = .small
        popup.font = .systemFont(ofSize: 11)
        popup.target = self
        popup.action = action
    }

    private static func durationTitle(_ minutes: Int?) -> String {
        guard let minutes else { return "不限" }
        return minutes < 60 ? "\(minutes) 分钟" : "\(minutes / 60) 小时"
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

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
        refreshKeepAwake()
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

    private func refreshKeepAwake() {
        let keepAwake = actions.keepAwake
        awakeSwitch.state = keepAwake.isActive ? .on : .off
        if let deadline = keepAwake.deadline {
            awakeSubtitle.stringValue = "将于 \(Self.clockFormatter.string(from: deadline)) 自动关闭"
        } else if !keepAwake.isActive, keepAwake.stoppedForLowBattery {
            awakeSubtitle.stringValue = "电量过低，已自动关闭"
        } else {
            awakeSubtitle.stringValue = "阻止自动息屏与闲置休眠"
        }

        lidSwitch.isEnabled = keepAwake.isLidAvailable
        lidSwitch.state = keepAwake.isLidAvailable && keepAwake.preventsLidSleep ? .on : .off
        lidSubtitle.stringValue = keepAwake.isLidAvailable ? "合上屏幕后继续运行" : "当前系统不支持"

        durationPopup.isEnabled = keepAwake.isActive
        durationPopup.selectItem(at: KeepAwakePolicy.durations.firstIndex(of: keepAwake.durationMinutes) ?? 0)
        batteryPopup.selectItem(at: KeepAwakePolicy.batteryThresholds.firstIndex(of: keepAwake.batteryThreshold) ?? 0)
    }

    @objc private func toggleAwake() {
        actions.keepAwake.setActive(awakeSwitch.state == .on)
        refresh()   // 低电量时开启会被立即关回，回读真实状态
    }
    @objc private func toggleLid() {
        actions.keepAwake.preventsLidSleep = lidSwitch.state == .on
        refresh()
    }
    @objc private func pickDuration() {
        let index = durationPopup.indexOfSelectedItem
        guard KeepAwakePolicy.durations.indices.contains(index) else { return }
        actions.keepAwake.setDuration(KeepAwakePolicy.durations[index])
        refresh()
    }
    @objc private func pickBattery() {
        let index = batteryPopup.indexOfSelectedItem
        guard KeepAwakePolicy.batteryThresholds.indices.contains(index) else { return }
        actions.keepAwake.batteryThreshold = KeepAwakePolicy.batteryThresholds[index]
        refresh()   // 调高阈值可能立即触发低电量关闭
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
