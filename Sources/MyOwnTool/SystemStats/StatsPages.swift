import AppKit

/// 坐标系自上而下的容器，方便页面内做“从顶部往下排”的布局
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 页面控件的小工厂
enum PageUI {
    static let contentX: CGFloat = 16
    static let contentWidth: CGFloat = 268

    static func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular,
                      mono: Bool = false, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    static func caption(_ text: String, y: CGFloat, in view: NSView) {
        let field = label(text, size: 10, color: .tertiaryLabelColor)
        field.frame = NSRect(x: contentX, y: y, width: contentWidth, height: 14)
        view.addSubview(field)
    }

    /// “左说明 + 右值”一行；value 为调用方持有的字段，此处只负责摆放
    static func addInfoRow(_ title: String, value: NSTextField, y: CGFloat, in view: NSView) {
        let name = label(title, size: 11, color: .secondaryLabelColor)
        name.frame = NSRect(x: contentX, y: y, width: 110, height: 15)
        view.addSubview(name)
        value.alignment = .right
        value.frame = NSRect(x: contentX + 110, y: y, width: contentWidth - 110, height: 15)
        view.addSubview(value)
    }
}

// MARK: - 占用页

/// CPU / GPU / 内存 三段，各带 30 秒曲线
final class UsagePage: FlippedView {
    private let cpuValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let gpuValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let ramValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let cpuChart = LineChartView(capacity: 30)
    private let gpuChart = LineChartView(capacity: 30)
    private let ramChart = LineChartView(capacity: 30)

    init() {
        super.init(frame: .zero)
        addSection("CPU", value: cpuValue, chart: cpuChart, tint: .systemBlue, y: 12)
        addSection("GPU", value: gpuValue, chart: gpuChart, tint: .systemPurple, y: 98)
        addSection("内存", value: ramValue, chart: ramChart, tint: .systemTeal, y: 184)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addSection(_ title: String, value: NSTextField, chart: LineChartView,
                            tint: NSColor, y: CGFloat) {
        let name = PageUI.label(title, size: 12, weight: .semibold)
        name.frame = NSRect(x: PageUI.contentX, y: y, width: 120, height: 16)
        addSubview(name)
        value.alignment = .right
        value.frame = NSRect(x: PageUI.contentX + 120, y: y, width: PageUI.contentWidth - 120, height: 16)
        addSubview(value)
        chart.frame = NSRect(x: PageUI.contentX, y: y + 20, width: PageUI.contentWidth, height: 52)
        addSubview(chart)
        chartTints[ObjectIdentifier(chart)] = tint
    }

    private var chartTints: [ObjectIdentifier: NSColor] = [:]

    func update(_ history: [StatsSample]) {
        guard let last = history.last else { return }
        cpuValue.stringValue = StatsFormat.percent(last.cpuUsage)
        gpuValue.stringValue = StatsFormat.percent(last.gpuUsage)
        ramValue.stringValue = "\(StatsFormat.percent(last.ramUsage))（\(StatsFormat.gigabytes(last.ramUsed))/\(StatsFormat.gigabytes(last.ramTotal)) GB）"

        for (chart, values) in [(cpuChart, history.map(\.cpuUsage)),
                                (gpuChart, history.map(\.gpuUsage)),
                                (ramChart, history.map(\.ramUsage))] {
            chart.update([.init(values: values, color: chartTints[ObjectIdentifier(chart)] ?? .controlAccentColor)])
        }
    }
}

// MARK: - 温度页

/// CPU / GPU 温度，30 秒曲线，曲线与数值颜色随温度档位变化
final class TempPage: FlippedView {
    private let cpuValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let gpuValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let cpuChart = LineChartView(capacity: 30)
    private let gpuChart = LineChartView(capacity: 30)

    init() {
        super.init(frame: .zero)
        for chart in [cpuChart, gpuChart] {
            chart.fixedMax = 100    // ℃ 满量程，曲线高低直观对应温度绝对值
        }
        addSection("CPU 温度", value: cpuValue, chart: cpuChart, y: 16)
        addSection("GPU 温度", value: gpuValue, chart: gpuChart, y: 152)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addSection(_ title: String, value: NSTextField, chart: LineChartView, y: CGFloat) {
        let name = PageUI.label(title, size: 12, weight: .semibold)
        name.frame = NSRect(x: PageUI.contentX, y: y, width: 120, height: 16)
        addSubview(name)
        value.alignment = .right
        value.frame = NSRect(x: PageUI.contentX + 120, y: y, width: PageUI.contentWidth - 120, height: 16)
        addSubview(value)
        chart.frame = NSRect(x: PageUI.contentX, y: y + 20, width: PageUI.contentWidth, height: 96)
        addSubview(chart)
    }

    func update(_ history: [StatsSample]) {
        guard let last = history.last else { return }
        updateSection(value: cpuValue, chart: cpuChart, temp: last.cpuTemp,
                      values: history.map { $0.cpuTemp ?? 0 })
        updateSection(value: gpuValue, chart: gpuChart, temp: last.gpuTemp,
                      values: history.map { $0.gpuTemp ?? 0 })
    }

    private func updateSection(value: NSTextField, chart: LineChartView, temp: Double?, values: [Double]) {
        value.stringValue = temp.map { String(format: "%.1f℃", $0) } ?? "—"
        let color = StatsBarView.tempColor(temp) ?? .secondaryLabelColor
        value.textColor = color
        chart.update([.init(values: values, color: color)])
    }
}

// MARK: - 网络页

/// 仿 Stats 网络页：下载/上传大字 + 上下镜像负载历史 + 出口接口/内网 IP/国内外公网 IP
final class NetworkPage: FlippedView {
    private static let upColor = NSColor.systemRed
    private static let downColor = NSColor.systemBlue

    private let downValue = PageUI.label(size: 20, weight: .semibold, mono: true)
    private let upValue = PageUI.label(size: 20, weight: .semibold, mono: true)
    private let chart = MirrorChartView(capacity: 30)
    private let interfaceValue = PageUI.label("—", size: 11, mono: true)
    private let localIPValue = PageUI.label("—", size: 11, mono: true)
    private let domesticIPValue = PageUI.label("—", size: 11, mono: true)
    private let foreignIPValue = PageUI.label("—", size: 11, mono: true)

    private let publicIP = PublicIPFetcher()

    init() {
        super.init(frame: .zero)

        // 大字：左下载右上传（与镜像图中 蓝=下载 红=上传 一致）
        downValue.frame = NSRect(x: PageUI.contentX, y: 8, width: 130, height: 26)
        upValue.frame = NSRect(x: PageUI.contentX + 138, y: 8, width: 130, height: 26)
        addSubview(downValue)
        addSubview(upValue)
        addLegend("下载", color: Self.downColor, x: PageUI.contentX, y: 36)
        addLegend("上传", color: Self.upColor, x: PageUI.contentX + 138, y: 36)

        PageUI.caption("负载历史（上=上传 下=下载）", y: 58, in: self)
        chart.upColor = Self.upColor
        chart.downColor = Self.downColor
        chart.frame = NSRect(x: PageUI.contentX, y: 74, width: PageUI.contentWidth, height: 92)
        addSubview(chart)

        PageUI.caption("接口与地址", y: 174, in: self)
        PageUI.addInfoRow("接口", value: interfaceValue, y: 190, in: self)
        PageUI.addInfoRow("内网 IP", value: localIPValue, y: 212, in: self)
        PageUI.addInfoRow("公网 IP（国内）", value: domesticIPValue, y: 234, in: self)
        PageUI.addInfoRow("公网 IP（国外）", value: foreignIPValue, y: 256, in: self)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func addLegend(_ text: String, color: NSColor, x: CGFloat, y: CGFloat) {
        let square = NSAttributedString(string: "■ ", attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: color,
        ])
        let title = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        let combined = NSMutableAttributedString(attributedString: square)
        combined.append(title)
        let field = NSTextField(labelWithString: "")
        field.attributedStringValue = combined
        field.frame = NSRect(x: x, y: y, width: 130, height: 15)
        addSubview(field)
    }

    /// 每次采样刷新速度与曲线
    func update(_ history: [StatsSample]) {
        guard let last = history.last else { return }
        downValue.stringValue = "\(StatsFormat.speed(last.netDown))/s"
        upValue.stringValue = "\(StatsFormat.speed(last.netUp))/s"
        chart.update(up: history.map(\.netUp), down: history.map(\.netDown))
    }

    /// 页面展示时刷新路由信息与公网 IP（公网 IP 有缓存）
    func onShow() {
        if let route = RouteInfo.current() {
            let name = route.displayName.map { "\($0) (\(route.bsdName))" } ?? route.bsdName
            interfaceValue.stringValue = name
            localIPValue.stringValue = route.localIP ?? "—"
        } else {
            interfaceValue.stringValue = "无网络"
            localIPValue.stringValue = "—"
        }
        applyPublicIP()
        publicIP.refreshIfStale { [weak self] in self?.applyPublicIP() }
    }

    private func applyPublicIP() {
        domesticIPValue.stringValue = Self.text(publicIP.domestic)
        foreignIPValue.stringValue = Self.text(publicIP.foreign)
    }

    private static func text(_ result: PublicIPFetcher.Result?) -> String {
        guard let result else { return "获取中…" }
        guard let note = result.note else { return result.ip }
        return "\(result.ip) · \(note)"
    }
}

// MARK: - 分屏页

/// 分屏功能的状态与设置（原菜单栏菜单的全部功能移到这里）
struct SnapPageActions {
    var isTrusted: () -> Bool
    var isSnapEnabled: () -> Bool
    var setSnapEnabled: (Bool) -> Void
    var loginItemState: () -> Bool?   // nil = 非 .app 运行，不可用
    var setLoginItem: (Bool) -> Void
    var openConfig: () -> Void
    var reloadConfig: () -> Void
    var openAXSettings: () -> Void
    var quit: () -> Void
}

final class SnapPage: FlippedView {
    private let actions: SnapPageActions
    private let permissionValue = PageUI.label(size: 11, weight: .semibold)
    private let axButton = NSButton(title: "打开「辅助功能」设置…", target: nil, action: nil)
    private let snapCheckbox = NSButton(checkboxWithTitle: "Shift 拖拽分屏", target: nil, action: nil)
    private let loginCheckbox = NSButton(checkboxWithTitle: "开机时自动启动", target: nil, action: nil)

    init(actions: SnapPageActions) {
        self.actions = actions
        super.init(frame: .zero)

        let name = PageUI.label("辅助功能权限", size: 11, color: .secondaryLabelColor)
        name.frame = NSRect(x: PageUI.contentX, y: 16, width: 110, height: 15)
        addSubview(name)
        permissionValue.alignment = .right
        permissionValue.frame = NSRect(x: PageUI.contentX + 110, y: 16, width: PageUI.contentWidth - 110, height: 15)
        addSubview(permissionValue)

        axButton.target = self
        axButton.action = #selector(openAX)
        axButton.bezelStyle = .rounded
        axButton.font = .systemFont(ofSize: 11)
        axButton.frame = NSRect(x: PageUI.contentX, y: 40, width: 180, height: 24)
        addSubview(axButton)

        snapCheckbox.target = self
        snapCheckbox.action = #selector(toggleSnap)
        snapCheckbox.font = .systemFont(ofSize: 12)
        snapCheckbox.frame = NSRect(x: PageUI.contentX, y: 78, width: PageUI.contentWidth, height: 18)
        addSubview(snapCheckbox)

        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)
        loginCheckbox.font = .systemFont(ofSize: 12)
        loginCheckbox.frame = NSRect(x: PageUI.contentX, y: 104, width: PageUI.contentWidth, height: 18)
        addSubview(loginCheckbox)

        let configButton = NSButton(title: "编辑布局配置…", target: self, action: #selector(openConfig))
        configButton.bezelStyle = .rounded
        configButton.font = .systemFont(ofSize: 11)
        configButton.frame = NSRect(x: PageUI.contentX, y: 142, width: 130, height: 24)
        addSubview(configButton)

        let reloadButton = NSButton(title: "重新加载", target: self, action: #selector(reloadConfig))
        reloadButton.bezelStyle = .rounded
        reloadButton.font = .systemFont(ofSize: 11)
        reloadButton.frame = NSRect(x: PageUI.contentX + 138, y: 142, width: 130, height: 24)
        addSubview(reloadButton)

        let quitButton = NSButton(title: "退出 MyOwnTool", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded
        quitButton.font = .systemFont(ofSize: 11)
        quitButton.frame = NSRect(x: PageUI.contentX, y: 248, width: PageUI.contentWidth, height: 24)
        addSubview(quitButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 页面展示时同步当前状态
    func onShow() {
        let trusted = actions.isTrusted()
        permissionValue.stringValue = trusted ? "已授权" : "未授权（分屏不可用）"
        permissionValue.textColor = trusted ? .systemGreen : .systemRed
        axButton.isHidden = trusted
        snapCheckbox.state = actions.isSnapEnabled() ? .on : .off
        if let login = actions.loginItemState() {
            loginCheckbox.isHidden = false
            loginCheckbox.state = login ? .on : .off
        } else {
            loginCheckbox.isHidden = true
        }
    }

    @objc private func toggleSnap() { actions.setSnapEnabled(snapCheckbox.state == .on) }
    @objc private func toggleLogin() {
        actions.setLoginItem(loginCheckbox.state == .on)
        onShow()    // 注册可能失败，回读真实状态
    }
    @objc private func openAX() { actions.openAXSettings() }
    @objc private func openConfig() { actions.openConfig() }
    @objc private func reloadConfig() { actions.reloadConfig() }
    @objc private func quit() { actions.quit() }
}
