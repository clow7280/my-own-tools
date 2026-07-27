import AIUsageCore
import AppKit
import StatsCore

/// 卡片标题行右侧的 sparkline 时长胶囊（DESIGN.md「弹窗」）：
/// 档位文字 + chevron 符号，底色随悬停加深，点击在胶囊正下方弹出三档下拉菜单。
/// 文字用 NSTextField 保证与其他小字排版一致，命中测试收敛到自身，避免子视图吞掉点击。
/// 宽度随档位文字长度变化，以 `trailingX` 为锚点重排，保证始终右对齐于标题行。
final class SparklineRangeControl: NSView {
    /// 胶囊高度，圆角取其一半
    static let height: CGFloat = 15

    private static let horizontalPadding: CGFloat = 6
    private static let symbolGap: CGFloat = 3
    private static let symbolPointSize: CGFloat = 7
    /// 下拉菜单顶边与胶囊底边的间距
    private static let menuGap: CGFloat = 3

    private let textLabel = PageUI.label(size: 10, color: .tertiaryLabelColor)
    private let symbolView = NSImageView()
    private let symbolSize: NSSize
    private let onSelect: (SparklineRange) -> Void
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

    init(trailingX: CGFloat, topY: CGFloat, onSelect: @escaping (SparklineRange) -> Void) {
        self.trailingX = trailingX
        self.topY = topY
        self.onSelect = onSelect

        let symbol = NSImage(systemSymbolName: "chevron.up.chevron.down",
                             accessibilityDescription: "选择曲线时长")?
            .withSymbolConfiguration(.init(pointSize: Self.symbolPointSize, weight: .semibold))
        symbolSize = symbol?.size ?? NSSize(width: Self.symbolPointSize, height: Self.symbolPointSize)
        super.init(frame: .zero)

        addSubview(textLabel)
        symbolView.image = symbol
        symbolView.imageScaling = .scaleNone
        addSubview(symbolView)
        toolTip = "点击选择曲线时长"
        applyHoverStyle()
        // 初始化内的赋值不触发 didSet，直接铺一次文字与尺寸
        textLabel.stringValue = range.caption
        layoutCapsule()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 当前档位：驱动胶囊文字与下拉菜单的勾选项，赋值不回调 `onSelect`
    var range: SparklineRange = .oneMinute {
        didSet {
            textLabel.stringValue = range.caption
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
        syncHover()
    }

    /// 弹窗 orderOut、切换选项卡或菜单模态跟踪期间收不到 mouseExited，按指针实际位置回正
    private func syncHover() {
        isHovering = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true }

    override func mouseExited(with event: NSEvent) { isHovering = false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// 弹出三档下拉，当前档打勾。本视图未翻转，负 y 即胶囊下方；
    /// `positioning: nil` 让菜单左上角落在该点
    override func mouseDown(with event: NSEvent) {
        let menu = NSMenu()
        for option in SparklineRange.allCases {
            let item = NSMenuItem(title: option.caption, action: #selector(pickRange(_:)), keyEquivalent: "")
            item.target = self
            item.tag = option.rawValue
            item.state = option == range ? .on : .off
            menu.addItem(item)
        }
        _ = menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -Self.menuGap), in: self)
        syncHover()
    }

    @objc private func pickRange(_ sender: NSMenuItem) {
        guard let picked = SparklineRange(rawValue: sender.tag) else { return }
        onSelect(picked)
    }

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
