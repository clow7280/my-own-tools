import AIUsageCore
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

/// 卡片标题行右侧的 sparkline 时长切换胶囊（DESIGN.md「弹窗」）：
/// 档位文字 + chevron 符号，底色随悬停加深，点击循环下一档。
/// 文字用 NSTextField 保证与其他小字排版一致，命中测试收敛到自身，避免子视图吞掉点击。
/// 宽度随档位文字长度变化，以 `trailingX` 为锚点重排，保证始终右对齐于标题行。
final class SparklineRangeControl: NSView {
    /// 胶囊高度，圆角取其一半
    static let height: CGFloat = 15

    private static let horizontalPadding: CGFloat = 6
    private static let symbolGap: CGFloat = 3
    private static let symbolPointSize: CGFloat = 7

    private let textLabel = PageUI.label(size: 10, color: .tertiaryLabelColor)
    private let symbolView = NSImageView()
    private let symbolSize: NSSize
    private let onClick: () -> Void
    /// 胶囊右边界与顶边（父视图为翻转坐标的卡片）
    private let trailingX: CGFloat
    private let topY: CGFloat
    private var trackingArea: NSTrackingArea?

    private var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            applyHoverStyle()
        }
    }

    init(trailingX: CGFloat, topY: CGFloat, onClick: @escaping () -> Void) {
        self.trailingX = trailingX
        self.topY = topY
        self.onClick = onClick

        let symbol = NSImage(systemSymbolName: "chevron.up.chevron.down",
                             accessibilityDescription: "切换曲线时长")?
            .withSymbolConfiguration(.init(pointSize: Self.symbolPointSize, weight: .semibold))
        symbolSize = symbol?.size ?? NSSize(width: Self.symbolPointSize, height: Self.symbolPointSize)
        super.init(frame: .zero)

        addSubview(textLabel)
        symbolView.image = symbol
        symbolView.imageScaling = .scaleNone
        addSubview(symbolView)
        toolTip = "点击切换曲线时长"
        applyHoverStyle()
    }

    required init?(coder: NSCoder) { fatalError() }

    var title: String = "" {
        didSet {
            textLabel.stringValue = title
            layoutCapsule()
        }
    }

    /// 按当前文字重算胶囊宽度并贴回右边界
    private func layoutCapsule() {
        let text = textLabel.sizeThatFits(NSSize(width: 200, height: Self.height))
        let textWidth = ceil(text.width)
        let textHeight = ceil(text.height)
        let width = Self.horizontalPadding * 2 + textWidth + Self.symbolGap + symbolSize.width
        frame = NSRect(x: trailingX - width, y: topY, width: width, height: Self.height)
        textLabel.frame = NSRect(x: Self.horizontalPadding, y: ((Self.height - textHeight) / 2).rounded(),
                                 width: textWidth, height: textHeight)
        symbolView.frame = NSRect(x: width - Self.horizontalPadding - symbolSize.width,
                                  y: ((Self.height - symbolSize.height) / 2).rounded(),
                                  width: symbolSize.width, height: symbolSize.height)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private func applyHoverStyle() {
        let color: NSColor = isHovering ? .secondaryLabelColor : .tertiaryLabelColor
        textLabel.textColor = color
        symbolView.contentTintColor = color
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (isHovering ? StatsPalette.capsuleHoverBackground : StatsPalette.capsuleBackground).setFill()
        let radius = bounds.height / 2
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
        // 弹窗 orderOut 或切换选项卡时收不到 mouseExited，重建 tracking 时按指针实际位置回正
        isHovering = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }

    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) { onClick() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// 细横向用量条：轨道 + 从左向右填充；striped 时画品牌色斜纹（5 小时限额取消态）
final class UsageBar: NSView {
    var fraction: Double = 0 { didSet { needsDisplay = true } }
    var color: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    var striped = false { didSet { needsDisplay = true } }
    var segments: [AIUsageSegment] = [] {
        didSet {
            toolTip = Self.segmentToolTip(segments)
            needsDisplay = true
        }
    }

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

        // Codex 周用量：填充总长度仍表示 7 天已用百分比，细分隔线表示各 UTC 日期桶的贡献。
        let total = segments.reduce(0) { $0 + max($1.value, 0) }
        guard segments.count > 1, total > 0, width >= 12 else { return }
        NSGraphicsContext.current?.saveGraphicsState()
        track.addClip()
        StatsPalette.usageTrack.setFill()
        var cumulative = 0.0
        for day in segments.dropLast() {
            cumulative += max(day.value, 0)
            let x = width * CGFloat(cumulative / total)
            if x > 2, x < width - 2 {
                NSRect(x: x - 0.5, y: 0, width: 1, height: bounds.height).fill()
            }
        }
        NSGraphicsContext.current?.restoreGraphicsState()
    }

    private static func segmentToolTip(_ values: [AIUsageSegment]) -> String? {
        let total = values.reduce(0) { $0 + max($1.value, 0) }
        guard total > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MM-dd"
        let rows = values.map { value in
            let share = Int((max(value.value, 0) / total * 100).rounded())
            let label = value.date.map(formatter.string) ?? value.label
            return "\(label)  本周已用中的 \(share)%"
        }
        return (["每日用量（UTC）"] + rows).joined(separator: "\n")
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

    /// 峰值线显示阈值：窗口内的峰均差全部小于均值窗口平均值的 5% 时不画峰值线，
    /// 避免两条曲线几乎重合、只剩描边噪声
    private static let peakVisibilityRatio = 0.05

    /// 最近一次收到的历史，切换时长后不等下一秒采样就能立即重绘
    private var history: [StatsSample] = []
    /// 每张卡独立的时长档位与对应切换控件
    private var ranges: [SparklineRange.Slot: SparklineRange] = Dictionary(
        uniqueKeysWithValues: SparklineRange.Slot.allCases.map { ($0, SparklineRange.stored($0)) })
    private var rangeControls: [SparklineRange.Slot: SparklineRangeControl] = [:]

    // 占用率卡
    private let cpuSpark = SparklineView()
    private let gpuSpark = SparklineView()
    private let ramSpark = SparklineView()
    private let cpuValue = PageUI.label(size: 14, weight: .semibold, mono: true)
    private let gpuValue = PageUI.label(size: 14, weight: .semibold, mono: true)
    private let ramValue = PageUI.label(size: 14, weight: .semibold, mono: true)
    private let cpuCoresInfo = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)
    private let cpuLoadInfo = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)
    private let ramInfo = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)

    // 温度卡
    private let cpuTempSpark = SparklineView()
    private let gpuTempSpark = SparklineView()
    private let cpuTempValue = PageUI.label(size: 13, weight: .semibold, mono: true)
    private let gpuTempValue = PageUI.label(size: 13, weight: .semibold, mono: true)
    private let diskTempValue = PageUI.label(size: 12, weight: .semibold, mono: true)
    private let batteryTempValue = PageUI.label(size: 12, weight: .semibold, mono: true)

    // 磁盘卡
    private let readSpark = SparklineView()
    private let writeSpark = SparklineView()
    private let readValue = PageUI.label(size: 12.5, weight: .semibold)
    private let writeValue = PageUI.label(size: 12.5, weight: .semibold)
    private let readTotalLabel = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)
    private let writeTotalLabel = PageUI.label(size: 10, mono: true, color: .tertiaryLabelColor)

    // 网络卡
    private let downValue = PageUI.label(size: 19, weight: .semibold)
    private let upValue = PageUI.label(size: 19, weight: .semibold)
    private let netSpark = SparklineView()
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

    /// 卡片标题行：左标题 + 右侧本卡的 sparkline 时长切换胶囊。
    /// 胶囊高 15 顶边 7，与 y=8 高 14 的标题视觉居中对齐，且不越到 y=30 的内容区
    private func addHeader(_ title: String, in card: CardView, slot: SparklineRange.Slot) {
        let header = PageUI.label(title, size: 11, weight: .semibold, color: .secondaryLabelColor)
        header.frame = NSRect(x: PageUI.cardPadding, y: 8, width: 120, height: 14)
        card.addSubview(header)

        let control = SparklineRangeControl(trailingX: PageUI.pageWidth - PageUI.cardPadding,
                                            topY: 7) { [weak self] in self?.cycleRange(slot) }
        control.title = range(slot).caption
        card.addSubview(control)
        rangeControls[slot] = control
    }

    private func range(_ slot: SparklineRange.Slot) -> SparklineRange { ranges[slot] ?? .oneMinute }

    /// 循环该卡到下一档时长：写回 UserDefaults、更新本卡文案，并立即用缓存历史只重绘本卡
    private func cycleRange(_ slot: SparklineRange.Slot) {
        let next = range(slot).next
        ranges[slot] = next
        SparklineRange.store(next, for: slot)
        rangeControls[slot]?.title = next.caption
        guard let last = history.last else { return }
        switch slot {
        case .usage: updateUsageCard(last)
        case .temperature: updateTempCard(last)
        case .disk: updateDiskCard(last)
        case .network: updateNetworkCard(last)
        }
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
        addHeader("占用率", in: card, slot: .usage)
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

        // 峰值已画进 sparkline，底部只留磁盘与电池两格
        let cellWidth = PageUI.innerWidth / 2
        for (index, (title, value)) in [("磁盘", diskTempValue), ("电池平均", batteryTempValue)].enumerated() {
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
        addHeader("温度", in: card, slot: .temperature)
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
        addHeader("磁盘", in: card, slot: .disk)
        return top + y
    }

    private func buildNetworkCard(top: CGFloat) -> CGFloat {
        var y: CGFloat = 30
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
        addHeader("网络", in: card, slot: .network)
        return top + y
    }

    // MARK: 刷新

    func update(_ history: [StatsSample]) {
        self.history = history
        guard let last = history.last else { return }
        updateUsageCard(last)
        updateTempCard(last)
        updateDiskCard(last)
        updateNetworkCard(last)
    }

    /// 按某张卡自己的档位降采样；取值时带上采样序号，分桶才能锚定绝对时间而非窗口位置
    private func mean(_ slot: SparklineRange.Slot, _ metric: (StatsSample) -> Double) -> [Double] {
        SparklineDownsample.average(history.map { (index: $0.sequence, value: metric($0)) },
                                    range: range(slot))
    }

    private func updateUsageCard(_ last: StatsSample) {
        cpuSpark.update([.init(values: mean(.usage, \.cpuUsage), color: StatsPalette.cpu)])
        gpuSpark.update([.init(values: mean(.usage, \.gpuUsage), color: StatsPalette.gpu)])
        ramSpark.update([.init(values: mean(.usage, \.ramUsage), color: StatsPalette.ram)])
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
    }

    /// 两条温度线同属温度卡，共用该卡档位
    private func updateTempCard(_ last: StatsSample) {
        let range = range(.temperature)
        updateTempSpark(cpuTempSpark, samples: history.compactMap { sample in
            sample.cpuTemp.map { (index: sample.sequence, mean: $0, peak: sample.cpuTempMax ?? $0) }
        }, range: range, meanColor: StatsPalette.cpuSoft, peakColor: StatsPalette.cpuFaint)
        updateTempSpark(gpuTempSpark, samples: history.compactMap { sample in
            sample.gpuTemp.map { (index: sample.sequence, mean: $0, peak: sample.gpuTempMax ?? $0) }
        }, range: range, meanColor: StatsPalette.gpuSoft, peakColor: StatsPalette.gpuFaint)
        applyTemp(cpuTempValue, last.cpuTemp)
        applyTemp(gpuTempValue, last.gpuTemp)
        diskTempValue.stringValue = tempText(last.diskTemp)
        batteryTempValue.stringValue = tempText(last.batteryTemp)
    }

    private func updateDiskCard(_ last: StatsSample) {
        readSpark.update([.init(values: mean(.disk, \.diskRead),
                                color: StatsPalette.neutralPrimary, lineWidth: 1.4)])
        writeSpark.update([.init(values: mean(.disk, \.diskWrite),
                                 color: StatsPalette.neutralSecondary, lineWidth: 1.4)])
        readValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.diskRead), unit: "MB/s",
                                                               numberSize: 12.5, unitSize: 10)
        writeValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.diskWrite), unit: "MB/s",
                                                                numberSize: 12.5, unitSize: 10)
        readTotalLabel.stringValue = "累计读取 \(StatsFormat.dataVolume(last.diskReadTotal))"
        writeTotalLabel.stringValue = "累计写入 \(StatsFormat.dataVolume(last.diskWriteTotal))"
    }

    private func updateNetworkCard(_ last: StatsSample) {
        netSpark.update([
            .init(values: mean(.network, \.netDown), color: StatsPalette.neutralPrimary, lineWidth: 1.4),
            .init(values: mean(.network, \.netUp), color: StatsPalette.neutralSecondary, lineWidth: 1.2),
        ])
        downValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.netDown), unit: "MB/s",
                                                               numberSize: 19, unitSize: 11)
        upValue.attributedStringValue = PageUI.valueWithUnit(StatsFormat.mbps(last.netUp), unit: "MB/s",
                                                             numberSize: 19, unitSize: 11,
                                                             color: .secondaryLabelColor)
    }

    /// 温度 sparkline：均值线（桶内平均）+ 峰值线（桶内最高核心温度，更细更弱）。
    /// 峰均差全部小于均值窗口平均值的 `peakVisibilityRatio` 时省略峰值线（DESIGN.md「弹窗」）。
    private func updateTempSpark(_ spark: SparklineView, samples: [(index: Int, mean: Double, peak: Double)],
                                 range: SparklineRange, meanColor: NSColor, peakColor: NSColor) {
        // 两条线共用同一套采样序号，桶边界完全对齐
        let means = SparklineDownsample.average(samples.map { (index: $0.index, value: $0.mean) }, range: range)
        guard !means.isEmpty else {
            spark.update([])
            return
        }
        // 峰值线排在均值线之前，绘制时被均值线覆盖，保持弱线在下
        var series: [SparklineView.Series] = []
        let peaks = SparklineDownsample.maximum(samples.map { (index: $0.index, value: $0.peak) }, range: range)
        let average = means.reduce(0, +) / Double(means.count)
        let spread = zip(peaks, means).map { $0 - $1 }.max() ?? 0
        if spread >= average * Self.peakVisibilityRatio {
            series.append(.init(values: peaks, color: peakColor, lineWidth: 1))
        }
        series.append(.init(values: means, color: meanColor))
        spark.update(series)
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
    var presentation: AIProviderPresentation
    var state: () -> AIProviderState
    var refresh: () -> Void
}

/// ChatGPT / Claude / OpenCode 各一张卡片：标题行 + 各订阅窗口与专属模型用量条（设计稿 3b）
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
        private let refreshSpinner = NSProgressIndicator()
        private let badge: BadgeView
        private let errorLabel = PageUI.label(size: 11, color: .secondaryLabelColor)
        private var rows: [UsageRow] = []

        private var standard: NSColor { self.spec.presentation.standardColor }
        private var deep: NSColor { self.spec.presentation.deepColor }

        init(spec: AIProviderSpec) {
            self.spec = spec
            nameLabel = PageUI.label(spec.presentation.displayName, size: 13, weight: .semibold)
            badge = BadgeView(
                textColor: spec.presentation.badgeTextColor,
                background: spec.presentation.badgeBackgroundColor)
            super.init(frame: .zero)

            addSubview(nameLabel)
            addSubview(updatedLabel)
            addSubview(errorLabel)
            addSubview(badge)
            errorLabel.maximumNumberOfLines = 0
            errorLabel.lineBreakMode = .byWordWrapping

            refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
            refreshButton.bezelStyle = .circular
            refreshButton.controlSize = .small
            refreshButton.target = self
            refreshButton.action = #selector(refreshTapped)
            addSubview(refreshButton)

            refreshSpinner.style = .spinning
            refreshSpinner.controlSize = .small
            refreshSpinner.isDisplayedWhenStopped = false
            refreshSpinner.isHidden = true
            addSubview(refreshSpinner)
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func refreshTapped() { spec.refresh() }

        /// 填充数据、重排并返回卡片高度
        func apply() -> CGFloat {
            let state = self.spec.state()
            let usage = state.snapshot
            let hasData = usage?.hasData == true

            // 标题行
            nameLabel.frame = NSRect(x: PageUI.cardPadding, y: 11, width: 120, height: 17)
            nameLabel.sizeToFit()
            nameLabel.setFrameOrigin(NSPoint(x: PageUI.cardPadding, y: 11))
            updatedLabel.stringValue = Self.sourceStatus(state)
            updatedLabel.toolTip = updatedLabel.stringValue
            updatedLabel.frame = NSRect(x: nameLabel.frame.maxX + 7, y: 14, width: 130, height: 13)

            // 刷新按钮固定在最右，订阅徽章排在其左侧
            let buttonSize: CGFloat = 20
            refreshButton.frame = NSRect(x: PageUI.pageWidth - PageUI.cardPadding - buttonSize,
                                         y: 9, width: buttonSize, height: buttonSize)
            refreshSpinner.frame = NSRect(x: refreshButton.frame.midX - 7, y: refreshButton.frame.midY - 7,
                                          width: 14, height: 14)
            let refreshing = state.isRefreshing
            refreshButton.isHidden = refreshing
            refreshButton.isEnabled = !refreshing
            refreshSpinner.isHidden = !refreshing
            if refreshing { refreshSpinner.startAnimation(nil) } else { refreshSpinner.stopAnimation(nil) }

            badge.text = usage?.plan?.displayName ?? ""
            badge.isHidden = badge.text.isEmpty
            badge.setFrameOrigin(NSPoint(x: refreshButton.frame.minX - 6 - badge.frame.width, y: 11))

            var y: CGFloat = 37
            let issue = Self.issueText(state)
            errorLabel.stringValue = issue ?? (hasData ? "" : "暂无数据")
            errorLabel.toolTip = issue
            if !hasData {
                let errorHeight = self.issueHeight(errorLabel.stringValue)
                errorLabel.isHidden = false
                errorLabel.frame = NSRect(
                    x: PageUI.cardPadding,
                    y: y,
                    width: PageUI.innerWidth,
                    height: errorHeight)
                rows.forEach { $0.isHidden = true }
                return y + errorHeight + 11
            }

            // 订阅窗口与扩展窗口；新增厂商只需注册 presentation，无需增加 Kind 分支。
            var configs: [UsageRow.Config] = []
            for item in self.spec.presentation.windows {
                let window = usage?.window(item.id)
                configs.append(.init(
                    title: item.title,
                    fraction: window?.fraction,
                    color: self.standard,
                    striped: window?.value == .notEnforced,
                    caption: Self.resetText(window?.resetsAt),
                    segments: window?.segments ?? []))
            }
            for window in usage?.extraWindows ?? [] {
                configs.append(.init(
                    title: window.title ?? "扩展窗口",
                    fraction: window.fraction,
                    color: self.deep,
                    striped: window.value == .notEnforced,
                    caption: Self.resetText(window.resetsAt),
                    segments: window.segments))
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
            y -= 6
            if let issue {
                let errorHeight = self.issueHeight(issue)
                errorLabel.isHidden = false
                errorLabel.frame = NSRect(
                    x: PageUI.cardPadding,
                    y: y + 6,
                    width: PageUI.innerWidth,
                    height: errorHeight)
                y += errorHeight + 6
            } else {
                errorLabel.isHidden = true
            }
            return y + 11
        }

        private func issueHeight(_ text: String) -> CGFloat {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: PageUI.innerWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: self.errorLabel.font ?? NSFont.systemFont(ofSize: 11),
                    .paragraphStyle: paragraph,
                ])
            return max(15, ceil(bounds.height))
        }

        private static func relativeTime(_ date: Date?) -> String {
            guard let date else { return "" }
            let seconds = -date.timeIntervalSinceNow
            if seconds < 90 { return "刚刚更新" }
            if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前更新" }
            return "\(Int(seconds / 3600)) 小时前更新"
        }

        private static func sourceStatus(_ state: AIProviderState) -> String {
            let time = self.relativeTime(state.lastDataAt)
            let source: String? = switch state.source?.quality {
            case .live: state.source.map { $0.label + " 实时" }
            case .estimated: state.source?.label ?? "本地估算"
            case .cached: state.source?.label ?? "本地快照"
            case nil: nil
            }
            return [source, time].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " · ")
        }

        private static func issueText(_ state: AIProviderState) -> String? {
            var messages: [String] = []
            if let failure = state.failure { messages.append(failure.message) }
            messages.append(contentsOf: state.partialFailures.map { "可选明细：" + $0.message })
            return messages.isEmpty ? nil : messages.joined(separator: "；")
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
            var segments: [AIUsageSegment]
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
            bar.segments = config.segments
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
    var aiRefreshInterval: () -> TimeInterval
    var setAIRefreshInterval: (TimeInterval) -> Void
    var aiStaleInterval: () -> TimeInterval
    var setAIStaleInterval: (TimeInterval) -> Void
    var openConfig: () -> Void
    var openAXSettings: () -> Void
    var lastLayoutLoad: () -> Date?
    var restart: () -> Void
    var quit: () -> Void
}

/// 拖拽分屏 / AI 用量 / 开机自启 / 版本与重启退出（设计稿 3c）
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
    private let intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let stalePopup = NSPopUpButton(frame: .zero, pullsDown: false)

    private static let rowHeight: CGFloat = 44

    init(actions: SettingsActions) {
        self.actions = actions
        super.init(frame: .zero)

        var y: CGFloat = 0
        y = buildSnapCard(top: y) + PageUI.cardGap
        y = buildAICard(top: y) + PageUI.cardGap
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

    /// AI 用量卡片：自动刷新间隔 + 数据过期阈值
    private func buildAICard(top: CGFloat) -> CGFloat {
        let card = CardView()
        var y: CGFloat = 2

        _ = addRow("AI 用量自动刷新", subtitle: "后台按此间隔拉取 ChatGPT、Claude 与 OpenCode 用量", y: y, in: card)
        intervalPopup.controlSize = .small
        intervalPopup.font = .systemFont(ofSize: 11)
        intervalPopup.target = self
        intervalPopup.action = #selector(changeInterval)
        intervalPopup.removeAllItems()
        intervalPopup.addItems(withTitles: AIUsageMonitor.intervalOptions.map(Self.intervalTitle))
        placeTrailing(intervalPopup, y: y, size: NSSize(width: 84, height: 22), in: card)
        y += Self.rowHeight
        PageUI.separator(in: card, y: y)

        _ = addRow("数据过期阈值", subtitle: "拉取失败超过该时长后，菜单栏叹号由黄转红", y: y, in: card)
        stalePopup.controlSize = .small
        stalePopup.font = .systemFont(ofSize: 11)
        stalePopup.target = self
        stalePopup.action = #selector(changeStaleInterval)
        stalePopup.removeAllItems()
        stalePopup.addItems(withTitles: AIUsageMonitor.staleOptions.map(Self.intervalTitle))
        placeTrailing(stalePopup, y: y, size: NSSize(width: 84, height: 22), in: card)
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

    /// 间隔秒数 → 「N 分钟」，整小时显示「N 小时」
    private static func intervalTitle(_ seconds: TimeInterval) -> String {
        seconds >= 3600 ? "\(Int(seconds / 3600)) 小时" : "\(Int(seconds / 60)) 分钟"
    }

    private func buildFooter(top: CGFloat) -> CGFloat {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "MyOwnTools"
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.2"
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

        let interval = actions.aiRefreshInterval()
        let intervalIndex = AIUsageMonitor.intervalOptions.firstIndex(of: interval) ?? 0
        intervalPopup.selectItem(at: intervalIndex)

        let stale = actions.aiStaleInterval()
        let staleIndex = AIUsageMonitor.staleOptions.firstIndex(of: stale)
            ?? AIUsageMonitor.staleOptions.firstIndex(of: AIUsageMonitor.defaultStaleInterval) ?? 0
        stalePopup.selectItem(at: staleIndex)

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
    @objc private func changeInterval() {
        let index = intervalPopup.indexOfSelectedItem
        guard AIUsageMonitor.intervalOptions.indices.contains(index) else { return }
        actions.setAIRefreshInterval(AIUsageMonitor.intervalOptions[index])
    }
    @objc private func changeStaleInterval() {
        let index = stalePopup.indexOfSelectedItem
        guard AIUsageMonitor.staleOptions.indices.contains(index) else { return }
        actions.setAIStaleInterval(AIUsageMonitor.staleOptions[index])
    }
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
