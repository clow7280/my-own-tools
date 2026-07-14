import AppKit

/// 菜单栏内容视图：左侧网速两行数字（上=上传 下=下载），
/// 右侧 CPU/GPU/RAM 三条竖向进度条（从底向上，填充色=DESIGN.md 指标色）。
/// CPU/GPU 条的描边颜色表示温度（绿 <60℃、橙 60~80℃、红 ≥80℃）。
/// 固定总宽避免数字跳动引起菜单栏抖动；作为 button 子视图自动跟随菜单栏明暗。
/// 横向进度条样式预留给将来的 AI 订阅用量段。
final class StatsBarView: NSView {
    // 布局常量：[边距][网速块][间距][竖条块][边距]；将来加 AI 用量段时在此扩展
    private static let margin: CGFloat = 4
    private static let speedWidth: CGFloat = 26
    private static let gap: CGFloat = 6
    private static let barsWidth: CGFloat = barWidth * 3 + barGap * 2
    static let totalWidth: CGFloat = margin + speedWidth + gap + barsWidth + margin

    private static let barWidth: CGFloat = 4
    private static let barHeight: CGFloat = 16
    private static let barGap: CGFloat = 4

    /// 单次采样间变化量超过该值时，该条提亮一拍以突出突发活动
    private static let highlightDelta = 0.3

    private var sample = StatsSample()
    private var previous = StatsSample()

    override var isFlipped: Bool { true }

    // 点击穿透到 status item 的 button，由它触发弹窗
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ sample: StatsSample) {
        previous = self.sample
        self.sample = sample
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSpeed()
        drawBars()
    }

    // MARK: - 网速

    private func drawSpeed() {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ]
        let up = NSAttributedString(string: StatsFormat.speed(sample.netUp), attributes: attrs)
        let down = NSAttributedString(string: StatsFormat.speed(sample.netDown), attributes: attrs)

        let right = Self.margin + Self.speedWidth
        let lineHeight = bounds.height / 2
        // 两行分别在上下半区垂直居中，数字右对齐
        up.draw(at: NSPoint(x: right - up.size().width, y: (lineHeight - up.size().height) / 2 + 1))
        down.draw(at: NSPoint(x: right - down.size().width, y: lineHeight + (lineHeight - down.size().height) / 2 - 1))
    }

    // MARK: - 进度条

    private func drawBars() {
        var x = Self.margin + Self.speedWidth + Self.gap
        let y = (bounds.height - Self.barHeight) / 2

        drawBar(x: x, y: y, usage: sample.cpuUsage, fill: StatsPalette.cpu,
                stroke: Self.tempColor(sample.cpuTemp),
                highlight: abs(sample.cpuUsage - previous.cpuUsage) > Self.highlightDelta)
        x += Self.barWidth + Self.barGap
        drawBar(x: x, y: y, usage: sample.gpuUsage, fill: StatsPalette.gpu,
                stroke: Self.tempColor(sample.gpuTemp),
                highlight: abs(sample.gpuUsage - previous.gpuUsage) > Self.highlightDelta)
        x += Self.barWidth + Self.barGap
        drawBar(x: x, y: y, usage: sample.ramUsage, fill: StatsPalette.ram, stroke: nil,
                highlight: abs(sample.ramUsage - previous.ramUsage) > Self.highlightDelta)
    }

    /// 竖向进度条：从底向上填充（flipped 坐标系下即从 maxY 往上）；
    /// highlight 时填充提亮一档，下一拍变化回落后自然恢复
    private func drawBar(x: CGFloat, y: CGFloat, usage: Double, fill: NSColor,
                         stroke: NSColor?, highlight: Bool) {
        let track = NSRect(x: x, y: y, width: Self.barWidth, height: Self.barHeight)
        let radius = Self.barWidth / 2

        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let fillHeight = max(Self.barWidth, Self.barHeight * min(max(usage, 0), 1))
        let fillColor = highlight ? (fill.blended(withFraction: 0.4, of: .white) ?? fill) : fill
        fillColor.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: track.maxY - fillHeight,
                                         width: Self.barWidth, height: fillHeight),
                     xRadius: radius, yRadius: radius).fill()

        // 描边保持比填充暗淡（alpha 压低），不与填充争夺注意力
        if let stroke {
            stroke.withAlphaComponent(0.7).setStroke()
            let path = NSBezierPath(roundedRect: track.insetBy(dx: -1, dy: -1),
                                    xRadius: radius + 1, yRadius: radius + 1)
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// 温度 → 警示描边色；常温（<60℃）与无数据时不描边，保持安静
    static func tempColor(_ temp: Double?) -> NSColor? {
        guard let temp else { return nil }
        switch temp {
        case ..<60: return nil
        case ..<80: return .systemOrange
        default: return .systemRed
        }
    }
}
