import AppKit

/// 坐标系自上而下的容器，方便页面内做“从顶部往下排”的布局
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 弹窗卡片：圆角 10 + 动态半透明底色（DESIGN.md「弹窗」）
class CardView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        StatsPalette.cardBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

/// 卡片内 1pt 分隔线
final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        StatsPalette.separator.setFill()
        bounds.fill()
    }
}

/// 页面控件的小工厂与布局常量
enum PageUI {
    /// 弹窗内容宽（窗口 348 − 两侧 12）
    static let pageWidth: CGFloat = 324
    /// 卡片内容左右边距
    static let cardPadding: CGFloat = 12
    /// 卡片内容宽
    static let innerWidth: CGFloat = pageWidth - cardPadding * 2
    /// 卡片纵向间距
    static let cardGap: CGFloat = 10

    // 指标行三列：标签 42 | 曲线自适应 | 数值（普通 52 / 带单位 76），列间距 10
    static let rowLabelWidth: CGFloat = 42
    static let rowGap: CGFloat = 10

    static func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular,
                      mono: Bool = false, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// 数值 + 小号单位的复合文本（如 "312 MB/s"）
    static func valueWithUnit(_ number: String, unit: String,
                              numberSize: CGFloat, unitSize: CGFloat,
                              color: NSColor = .labelColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: number, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: numberSize, weight: .semibold),
            .foregroundColor: color,
        ])
        text.append(NSAttributedString(string: " " + unit, attributes: [
            .font: NSFont.systemFont(ofSize: unitSize, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    static func separator(in view: NSView, y: CGFloat) {
        let line = SeparatorView()
        line.frame = NSRect(x: cardPadding, y: y, width: innerWidth, height: 1)
        view.addSubview(line)
    }
}

/// 细横向用量条：轨道 + 从左向右填充；striped 时画品牌色斜纹（5 小时限额取消态）
final class UsageBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var striped = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius)

        if striped {
            NSGraphicsContext.current?.saveGraphicsState()
            track.addClip()
            color.withAlphaComponent(0.07).setFill()
            bounds.fill()
            color.withAlphaComponent(0.22).setFill()
            // 45° 斜纹：宽 4、间隔 4
            var x = -bounds.height
            while x < bounds.width {
                let stripe = NSBezierPath()
                stripe.move(to: NSPoint(x: x, y: bounds.maxY))
                stripe.line(to: NSPoint(x: x + bounds.height, y: 0))
                stripe.line(to: NSPoint(x: x + bounds.height + 4, y: 0))
                stripe.line(to: NSPoint(x: x + 4, y: bounds.maxY))
                stripe.close()
                stripe.fill()
                x += 8
            }
            NSGraphicsContext.current?.restoreGraphicsState()
            return
        }

        StatsPalette.usageTrack.setFill()
        track.fill()
        guard fraction > 0 else { return }
        let width = max(bounds.height, bounds.width * min(fraction, 1))
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius, yRadius: radius).fill()
    }
}

/// 订阅徽章：品牌色文字 + 低透明度品牌底的胶囊
final class BadgeView: NSView {
    private let textLabel: NSTextField
    private let background: NSColor

    init(textColor: NSColor, background: NSColor) {
        self.background = background
        textLabel = PageUI.label(size: 10, weight: .semibold, color: textColor)
        super.init(frame: .zero)
        addSubview(textLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    var text: String = "" {
        didSet {
            textLabel.stringValue = text
            let size = textLabel.sizeThatFits(NSSize(width: 200, height: 16))
            textLabel.frame = NSRect(x: 7, y: 2, width: size.width, height: size.height)
            setFrameSize(NSSize(width: size.width + 14, height: size.height + 4))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

// MARK: - 系统页

/// 占用率 / 温度 / 磁盘 / 网络四张卡片（设计稿 3a）
final class SystemPage: FlippedView {
    private(set) var contentHeight: CGFloat = 0

    // 占用率卡
    private let cpuSpark = SparklineView(capacity: StatsMonitor.historyCapacity)
    private let gpuSpark = SparklineView(capacity: StatsMonitor.historyCapacity)
    private let ramSpark = SparklineView(capacity: StatsMonitor.historyCapacity)
    private let cpuValue = PageUI.label(size: 14, weight: .semibold, mono: true)
    private let gpuValue = PageUI.label(size: 14, weight: .semibold, mono: true)
    private let ramValue = PageUI.label(size: 14, weight: .semibold, mono: true)
    private let cpuCoresInfo = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)
    private let cpuLoadInfo = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)
    private let ramInfo = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)

    // 温度卡
    private let cpuTempSpark = SparklineView(capacity: StatsMonitor.historyCapacity)
    private let gpuTempSpark = SparklineView(capacity: StatsMonitor.historyCapacity)
    private let cpuTempValue = PageUI.label(size: 13, weight: .semibold, mono: true)
    private let gpuTempValue = PageUI.label(size: 13, weight: .semibold, mono: true)
    private let cpuPeakValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let gpuPeakValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let diskTempValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let batteryTempValue = PageUI.label(size: 12, weight: .semibold, mono: true)

    // 磁盘卡
    private let readSpark = SparklineView(capacity: StatsMonitor.historyCapacity)
    private let writeSpark = SparklineView(capacity: StatsMonitor.historyCapacity)
    private let readValue = PageUI.label(size: 12.5, weight: .semibold)
    private let writeValue = PageUI.label(size: 12.5, weight: .semibold)
    private let readTotalLabel = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)
    private let writeTotalLabel = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)

    // 网络卡
    private let downValue = PageUI.label(size: 19, weight: .semibold)
    private let upValue = PageUI.label(size: 19, weight: .semibold)
    private let netSpark = SparklineView(capacity: StatsMonitor.historyCapacity)
    private let interfaceValue = PageUI.label("—", size: 12, weight: .medium)
    private let localIPValue = PageUI.label("—", size: 12, weight: .medium, mono: true)
    private let publicIPValue = PageUI.label("—", size: 12, weight: .medium, mono: true)
    private let publicIP = PublicIPFetcher()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        var y: CGFloat = 0
        y = buildUsageCard(top: y) + PageUI.cardGap
        y = buildTempCard(top: y) + PageUI.cardGap
        y = buildDiskCard(top: y) + PageUI.cardGap
        y = buildNetworkCard(top: y)
        contentHeight = y
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: 建卡

    private func addCard(top: CGFloat, height: CGFloat) -> CardView {
        let card = CardView()
        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: height)
        addSubview(card)
        return card
    }

    /// 卡片标题行：左标题 + 右简介（右对齐次级小字）
    private func addHeader(_ title: String, caption: String, in card: CardView) {
        let header = PageUI.label(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
        header.frame = NSRect(x: PageUI.cardPadding, y: 8, width: 120, height: 14)
        card.addSubview(header)
        let hint = PageUI.label(caption, size: 10, color: .tertiaryLabelColor)
        hint.alignment = .right
        hint.frame = NSRect(x: PageUI.cardPadding + 120, y: 9, width: PageUI.innerWidth - 120, height: 13)
        card.addSubview(hint)
    }

    /// 指标行：标签 | sparkline | 数值；返回行底
    @discardableResult
    private func addMetricRow(_ title: String, spark: SparklineView, sparkHeight: CGFloat,
                              value: NSTextField, valueWidth: CGFloat, y: CGFloat,
                              rowHeight: CGFloat, in card: CardView) -> CGFloat {
        let name = PageUI.label(title, size: 12, weight: .semibold)
        name.frame = NSRect(x: PageUI.cardPadding, y: y + (rowHeight - 15) / 2,
                            width: PageUI.rowLabelWidth, height: 15)
        card.addSubview(name)

        let sparkX = PageUI.cardPadding + PageUI.rowLabelWidth + PageUI.rowGap
        let sparkWidth = PageUI.innerWidth - PageUI.rowLabelWidth - valueWidth - PageUI.rowGap * 2
        spark.frame = NSRect(x: sparkX, y: y + (rowHeight - sparkHeight) / 2,
                             width: sparkWidth, height: sparkHeight)
        card.addSubview(spark)

        value.alignment = .right
        value.frame = NSRect(x: sparkX + sparkWidth + PageUI.rowGap, y: y + (rowHeight - 17) / 2,
                             width: valueWidth, height: 17)
        card.addSubview(value)
        return y + rowHeight
    }

    private func buildUsageCard(top: CGFloat) -> CGFloat {
        var y: CGFloat = 30    // 标题行 8+14，与内容间距 8
        let subIndent = PageUI.cardPadding + PageUI.rowLabelWidth + PageUI.rowGap

        let card = CardView()
        for spark in [cpuSpark, gpuSpark, ramSpark] { spark.scale = .fixed(max: 1) }

        y = addMetricRow("CPU", spark: cpuSpark, sparkHeight: 24, value: cpuValue,
                         valueWidth: 52, y: y, rowHeight: 24, in: card)
        cpuCoresInfo.frame = NSRect(x: subIndent, y: y + 3, width: 110, height: 13)
        cpuLoadInfo.alignment = .right
        cpuLoadInfo.frame = NSRect(x: subIndent + 110,
                                   y: y + 3, width: PageUI.pageWidth - PageUI.cardPadding - subIndent - 110, height: 13)
        card.addSubview(cpuCoresInfo)
        card.addSubview(cpuLoadInfo)
        y += 19
        PageUI.separator(in: card, y: y)
        y += 8

        y = addMetricRow("GPU", spark: gpuSpark, sparkHeight: 24, value: gpuValue,
                         valueWidth: 52, y: y, rowHeight: 24, in: card)
        y += 7
        PageUI.separator(in: card, y: y)
        y += 8

        y = addMetricRow("RAM", spark: ramSpark, sparkHeight: 24, value: ramValue,
                         valueWidth: 52, y: y, rowHeight: 24, in: card)
        ramInfo.frame = NSRect(x: subIndent, y: y + 3,
                               width: PageUI.pageWidth - PageUI.cardPadding - subIndent, height: 13)
        card.addSubview(ramInfo)
        y += 19 + 7

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        addHeader("占用率", caption: "近 1 分钟", in: card)
        return top + y
    }

    private func buildTempCard(top: CGFloat) -> CGFloat {
        var y: CGFloat = 30
        let card = CardView()
        cpuTempSpark.scale = .band(padding: 2)
        gpuTempSpark.scale = .band(padding: 2)

        y = addMetricRow("CPU", spark: cpuTempSpark, sparkHeight: 20, value: cpuTempValue,
                         valueWidth: 52, y: y, rowHeight: 20, in: card)
        y += 6
        PageUI.separator(in: card, y: y)
        y += 7
        y = addMetricRow("GPU", spark: gpuTempSpark, sparkHeight: 20, value: gpuTempValue,
                         valueWidth: 52, y: y, rowHeight: 20, in: card)
        y += 6
        PageUI.separator(in: card, y: y)
        y += 7

        let cellWidth = PageUI.innerWidth / 4
        for (index, (title, value)) in [("CPU 峰值", cpuPeakValue), ("GPU 峰值", gpuPeakValue),
                                        ("磁盘", diskTempValue), ("电池平均", batteryTempValue)].enumerated() {
            let x = PageUI.cardPadding + cellWidth * CGFloat(index)
            let caption = PageUI.label(title, size: 9.5, color: .tertiaryLabelColor)
            caption.frame = NSRect(x: x, y: y, width: cellWidth - 4, height: 12)
            value.frame = NSRect(x: x, y: y + 13, width: cellWidth - 4, height: 15)
            card.addSubview(caption)
            card.addSubview(value)
        }
        y += 31 + 8

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        addHeader("温度", caption: "1 分钟平均核心温度", in: card)
        return top + y
    }

    private func buildDiskCard(top: CGFloat) -> CGFloat {
        var y: CGFloat = 30
        let card = CardView()
        readSpark.scale = .autoMax(floor: 20_000_000)   // 20 MB/s 下限防空闲噪声放大
        writeSpark.scale = .autoMax(floor: 20_000_000)

        y = addMetricRow("读取", spark: readSpark, sparkHeight: 20, value: readValue,
                         valueWidth: 76, y: y, rowHeight: 20, in: card)
        y += 6
        PageUI.separator(in: card, y: y)
        y += 7
        y = addMetricRow("写入", spark: writeSpark, sparkHeight: 20, value: writeValue,
                         valueWidth: 76, y: y, rowHeight: 20, in: card)
        y += 6
        PageUI.separator(in: card, y: y)
        y += 7

        readTotalLabel.frame = NSRect(x: PageUI.cardPadding, y: y, width: PageUI.innerWidth / 2, height: 13)
        writeTotalLabel.alignment = .right
        writeTotalLabel.frame = NSRect(x: PageUI.cardPadding + PageUI.innerWidth / 2, y: y,
                                       width: PageUI.innerWidth / 2, height: 13)
        card.addSubview(readTotalLabel)
        card.addSubview(writeTotalLabel)
        y += 13 + 8

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        addHeader("磁盘", caption: "内置 SSD 读写", in: card)
        return top + y
    }

    private func buildNetworkCard(top: CGFloat) -> CGFloat {
        var y: CGFloat = 10
        let card = CardView()
        netSpark.scale = .autoMax(floor: 100_000)   // 100 KB/s 下限

        let columnWidth = PageUI.innerWidth / 2
        for (index, (title, value)) in [("下载", downValue), ("上传", upValue)].enumerated() {
            let x = PageUI.cardPadding + columnWidth * CGFloat(index)
            let caption = PageUI.label(title, size: 10.5, color: .tertiaryLabelColor)
            caption.frame = NSRect(x: x, y: y, width: columnWidth - 4, height: 13)
            value.frame = NSRect(x: x, y: y + 14, width: columnWidth - 4, height: 24)
            card.addSubview(caption)
            card.addSubview(value)
        }
        y += 14 + 24 + 8

        netSpark.frame = NSRect(x: PageUI.cardPadding, y: y, width: PageUI.innerWidth, height: 30)
        card.addSubview(netSpark)
        y += 30 + 8
        PageUI.separator(in: card, y: y)
        y += 7

        for (title, value) in [("出口接口", interfaceValue), ("内网 IP", localIPValue), ("公网 IP", publicIPValue)] {
            let name = PageUI.label(title, size: 12, color: .secondaryLabelColor)
            name.frame = NSRect(x: PageUI.cardPadding, y: y, width: 110, height: 16)
            value.alignment = .right
            value.frame = NSRect(x: PageUI.cardPadding + 110, y: y,
                                 width: PageUI.innerWidth - 110, height: 16)
            card.addSubview(name)
            card.addSubview(value)
            y += 21
        }
        y += 3

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y)
        addSubview(card)
        return top + y
    }

    // MARK: 刷新

    func update(_ history: [StatsSample]) {
        guard let last = history.last else { return }

        cpuSpark.update([.init(values: history.map(\.cpuUsage), color: StatsPalette.cpu)])
        gpuSpark.update([.init(values: history.map(\.gpuUsage), color: StatsPalette.gpu)])
        ramSpark.update([.init(values: history.map(\.ramUsage), color: StatsPalette.ram)])
        cpuValue.stringValue = StatsFormat.percent(last.cpuUsage)
        gpuValue.stringValue = StatsFormat.percent(last.gpuUsage)
        ramValue.stringValue = StatsFormat.percent(last.ramUsage)

        if let e = last.cpuECore, let p = last.cpuPCore {
            cpuCoresInfo.stringValue = "E 核 \(StatsFormat.percent(e))  P 核 \(StatsFormat.percent(p))"
        } else {
            cpuCoresInfo.stringValue = ""
        }
        cpuLoadInfo.stringValue = last.loadAvg.count == 3
            ? String(format: "负载 %.2f / %.2f / %.2f", last.loadAvg[0], last.loadAvg[1], last.loadAvg[2])
            : ""
        ramInfo.stringValue = "App \(StatsFormat.gigabytes(last.ramApp)) GB · 联动 \(StatsFormat.gigabytes(last.ramWired)) GB · SWAP \(StatsFormat.gigabytes(last.swapUsed)) GB"

        cpuTempSpark.update([.init(values: history.compactMap(\.cpuTemp), color: StatsPalette.cpuSoft)])
        gpuTempSpark.update([.init(values: history.compactMap(\.gpuTemp), color: StatsPalette.gpuSoft)])
        applyTemp(cpuTempValue, last.cpuTemp)
        applyTemp(gpuTempValue, last.gpuTemp)
        cpuPeakValue.stringValue = tempText(last.cpuTempMax)
        gpuPeakValue.stringValue = tempText(last.gpuTempMax)
        diskTempValue.stringValue = tempText(last.diskTemp)
        batteryTempValue.stringValue = tempText(last.batteryTemp)

        readSpark.update([.init(values: history.map(\.diskRead), color: StatsPalette.neutralPrimary, lineWidth: 1.4)])
        writeSpark.update([.init(values: history.map(\.diskWrite), color: StatsPalette.neutralSecondary, lineWidth: 1.4)])
        readValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.diskRead), unit: "MB/s",
                                                               numberSize: 12.5, unitSize: 10)
        writeValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.diskWrite), unit: "MB/s",
                                                                numberSize: 12.5, unitSize: 10)
        readTotalLabel.stringValue = "累计读取 \(StatsFormat.dataVolume(last.diskReadTotal))"
        writeTotalLabel.stringValue = "累计写入 \(StatsFormat.dataVolume(last.diskWriteTotal))"

        netSpark.update([
            .init(values: history.map(\.netDown), color: StatsPalette.neutralPrimary, lineWidth: 1.4),
            .init(values: history.map(\.netUp), color: StatsPalette.neutralSecondary, lineWidth: 1.2),
        ])
        downValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.netDown), unit: "MB/s",
                                                               numberSize: 19, unitSize: 11)
        upValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.netUp), unit: "MB/s",
                                                             numberSize: 19, unitSize: 11,
                                                             color: .secondaryLabelColor)
    }

    /// 温度数值按分级着色（DESIGN.md 温度分级）；常温与无数据用默认标签色
    private func applyTemp(_ label: NSTextField, _ temp: Double?) {
        label.stringValue = tempText(temp)
        label.textColor = TempTier(temp)?.text ?? .labelColor
    }

    private func tempText(_ temp: Double?) -> String {
        temp.map { String(format: "%.0f°", $0) } ?? "—"
    }

    /// 页面展示时刷新路由信息与公网 IP（公网 IP 有缓存）
    func onShow() {
        if let route = RouteInfo.current() {
            interfaceValue.stringValue = route.displayName.map { "\(route.bsdName) · \($0)" } ?? route.bsdName
            localIPValue.stringValue = route.localIP ?? "—"
        } else {
            interfaceValue.stringValue = "无网络"
            localIPValue.stringValue = "—"
        }
        applyPublicIP()
        publicIP.refreshIfStale { [weak self] in self?.applyPublicIP() }
    }

    private func applyPublicIP() {
        publicIPValue.stringValue = publicIP.current?.ip ?? "获取中…"
    }
}

// MARK: - AI 页

/// AI 提供方的展示与交互配置（AppDelegate 装配）
struct AIProviderSpec {
    enum Kind {
        case chatGPT
        case claude
    }

    var kind: Kind
    var name: String
    var usage: () -> AIUsage
    var updatedAt: () -> Date?
    var refresh: () -> Void
}

/// ChatGPT / Claude 各一张卡片：标题行 + 5h / 7d / 专属模型用量条（设计稿 3b）
final class AIPage: FlippedView {
    private(set) var contentHeight: CGFloat = 0
    private var cards: [ProviderCard] = []

    init(providers: [AIProviderSpec]) {
        super.init(frame: .zero)
        for spec in providers {
            let card = ProviderCard(spec: spec)
            addSubview(card)
            cards.append(card)
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 重新填充数据并按各卡实际高度重排
    func update() {
        var y: CGFloat = 0
        for card in cards {
            let height = card.apply()
            card.frame = NSRect(x: 0, y: y, width: PageUI.pageWidth, height: height)
            y += height + PageUI.cardGap
        }
        contentHeight = y - PageUI.cardGap
    }

    /// 单家卡片
    private final class ProviderCard: CardView {
        private let spec: AIProviderSpec
        private let nameLabel: NSTextField
        private let updatedLabel = PageUI.label(size: 10, color: .tertiaryLabelColor)
        private let refreshButton = NSButton()
        private let badge: BadgeView
        private let errorLabel = PageUI.label(size: 11, color: .secondaryLabelColor)
        private var rows: [UsageRow] = []

        private var standard: NSColor {
            spec.kind == .chatGPT ? StatsPalette.chatGPT : StatsPalette.claude
        }
        private var dimColor: NSColor {
            spec.kind == .chatGPT ? StatsPalette.chatGPTDim : StatsPalette.claudeDim
        }
        private var deep: NSColor {
            spec.kind == .chatGPT ? StatsPalette.chatGPTDeep : StatsPalette.claudeDeep
        }

        init(spec: AIProviderSpec) {
            self.spec = spec
            nameLabel = PageUI.label(spec.name, size: 13, weight: .semibold)
            badge = BadgeView(textColor: spec.kind == .chatGPT ? StatsPalette.chatGPTDeep : StatsPalette.claudeDeep,
                              background: spec.kind == .chatGPT ? StatsPalette.chatGPTBadgeBG : StatsPalette.claudeBadgeBG)
            super.init(frame: .zero)

            addSubview(nameLabel)
            addSubview(updatedLabel)
            addSubview(errorLabel)
            addSubview(badge)

            refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
            refreshButton.bezelStyle = .circular
            refreshButton.controlSize = .small
            refreshButton.target = self
            refreshButton.action = #selector(refreshTapped)
            addSubview(refreshButton)
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func refreshTapped() { spec.refresh() }

        /// 填充数据、重排并返回卡片高度
        func apply() -> CGFloat {
            let usage = spec.usage()
            let hasData = usage.fiveHour != nil || usage.sevenDay != nil || !usage.models.isEmpty

            // 标题行
            nameLabel.frame = NSRect(x: PageUI.cardPadding, y: 11, width: 120, height: 17)
            nameLabel.sizeToFit()
            nameLabel.setFrameOrigin(NSPoint(x: PageUI.cardPadding, y: 11))
            updatedLabel.stringValue = usage.error ?? Self.relativeTime(spec.updatedAt())
            updatedLabel.frame = NSRect(x: nameLabel.frame.maxX + 7, y: 14, width: 130, height: 13)

            badge.text = AIUsage.planBadge(usage.plan) ?? ""
            badge.isHidden = badge.text.isEmpty
            let badgeX = PageUI.pageWidth - PageUI.cardPadding - badge.frame.width
            badge.setFrameOrigin(NSPoint(x: badgeX, y: 11))
            refreshButton.frame = NSRect(x: (badge.isHidden ? PageUI.pageWidth - PageUI.cardPadding : badgeX) - 24,
                                         y: 9, width: 20, height: 20)

            var y: CGFloat = 37
            errorLabel.isHidden = hasData
            if !hasData {
                errorLabel.stringValue = usage.error ?? "暂无数据"
                errorLabel.frame = NSRect(x: PageUI.cardPadding, y: y, width: PageUI.innerWidth, height: 15)
                rows.forEach { $0.isHidden = true }
                return y + 15 + 11
            }

            // 三类行：5 小时 / 7 天 / 专属模型
            var configs: [UsageRow.Config] = []
            if let five = usage.fiveHour {
                configs.append(.init(title: "5 小时窗口", fraction: five, color: standard,
                                     striped: false, caption: Self.resetText(usage.fiveHourResetsAt)))
            } else {
                // 限额暂时取消：品牌色斜纹，无百分比（设计稿 3b ChatGPT 态）
                configs.append(.init(title: "5 小时窗口", fraction: nil, color: standard,
                                     striped: true, caption: ""))
            }
            configs.append(.init(title: "7 天窗口", fraction: usage.sevenDay, color: dimColor,
                                 striped: false, caption: Self.resetText(usage.sevenDayResetsAt)))
            for model in usage.models {
                configs.append(.init(title: "\(model.name) 专属", fraction: model.percent, color: deep,
                                     striped: false, caption: Self.resetText(model.resetsAt)))
            }

            while rows.count < configs.count {
                let row = UsageRow()
                addSubview(row)
                rows.append(row)
            }
            for (index, row) in rows.enumerated() {
                guard index < configs.count else {
                    row.isHidden = true
                    continue
                }
                row.isHidden = false
                row.frame = NSRect(x: PageUI.cardPadding, y: y, width: PageUI.innerWidth, height: UsageRow.height)
                row.apply(configs[index])
                y += UsageRow.height + 6
            }
            return y - 6 + 11
        }

        private static func relativeTime(_ date: Date?) -> String {
            guard let date else { return "" }
            let seconds = -date.timeIntervalSinceNow
            if seconds < 90 { return "刚刚更新" }
            if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前更新" }
            return "\(Int(seconds / 3600)) 小时前更新"
        }

        /// 重置时间：24h 内显示倒计时，否则显示星期与时刻
        private static func resetText(_ date: Date?) -> String {
            guard let date else { return "" }
            let interval = date.timeIntervalSinceNow
            guard interval > 0 else { return "即将重置" }
            if interval < 24 * 3600 {
                let hours = Int(interval) / 3600
                let minutes = (Int(interval) % 3600) / 60
                return hours > 0 ? "\(hours)h \(minutes)m 后重置" : "\(minutes)m 后重置"
            }
            return Self.weekdayFormatter.string(from: date) + " 重置"
        }

        private static let weekdayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "EEE HH:mm"
            return formatter
        }()
    }

    /// 一条用量：标题 + 百分比 / 进度条 / 重置说明
    private final class UsageRow: FlippedView {
        struct Config {
            var title: String
            var fraction: Double?   // nil + striped = 限额取消；nil + !striped = 无数据
            var color: NSColor
            var striped: Bool
            var caption: String
        }

        static let height: CGFloat = 36

        private let titleLabel = PageUI.label(size: 11, color: .secondaryLabelColor)
        private let percentLabel = PageUI.label(size: 11, weight: .semibold, mono: true)
        private let bar = UsageBar()
        private let captionLabel = PageUI.label(size: 10, color: .tertiaryLabelColor)

        init() {
            super.init(frame: .zero)
            titleLabel.frame = NSRect(x: 0, y: 0, width: 200, height: 14)
            percentLabel.alignment = .right
            captionLabel.alignment = .right
            addSubview(titleLabel)
            addSubview(percentLabel)
            addSubview(bar)
            addSubview(captionLabel)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            percentLabel.frame = NSRect(x: bounds.width - 60, y: 0, width: 60, height: 14)
            bar.frame = NSRect(x: 0, y: 17, width: bounds.width, height: 6)
            captionLabel.frame = NSRect(x: bounds.width - 160, y: 26, width: 160, height: 13)
        }

        func apply(_ config: Config) {
            titleLabel.stringValue = config.title
            bar.color = config.color
            bar.striped = config.striped
            bar.fraction = config.fraction ?? 0
            percentLabel.stringValue = config.striped ? "" : config.fraction.map(StatsFormat.percent) ?? "—"
            captionLabel.stringValue = config.caption
            resizeSubviews(withOldSize: bounds.size)
        }
    }
}

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

/// 拖拽分屏 / 布局配置 / 辅助功能权限 / 开机自启 / 版本与重启退出（设计稿 3c）
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

        _ = addRow("拖拽分屏", subtitle: "按住 Shift 拖动窗口即可吸附至分区", y: y, in: card)
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
        let y: CGFloat = 2
        loginSubtitle.stringValue = "登录时静默启动，无 Dock 图标"
        _ = addRow("开机自启", subtitle: nil, y: y, in: card)
        loginSubtitle.frame = NSRect(x: PageUI.cardPadding, y: y + 24, width: PageUI.innerWidth - 90, height: 13)
        card.addSubview(loginSubtitle)
        loginSwitch.controlSize = .small
        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin)
        placeTrailing(loginSwitch, y: y, size: loginSwitch.intrinsicContentSize, in: card)

        card.frame = NSRect(x: 0, y: top, width: PageUI.pageWidth, height: y + Self.rowHeight)
        addSubview(card)
        return top + y + Self.rowHeight
    }

    private func buildFooter(top: CGFloat) -> CGFloat {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "MyOwnTools"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0"
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
