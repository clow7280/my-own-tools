import AppKit

/// 菜单栏内容视图：左侧网速两行数字（上=上传 下=下载），右侧 CPU/GPU/RAM 三条迷你进度条。
/// CPU/GPU 条的描边颜色表示温度（绿 <60℃、橙 60~80℃、红 ≥80℃）。
/// 固定总宽避免数字跳动引起菜单栏抖动；作为 button 子视图自动跟随菜单栏明暗。
final class StatsBarView: NSView {
    // 布局常量：[边距][网速块][间距][进度条块][边距]；将来加 AI 用量段时在此扩展
    private static let margin: CGFloat = 4
    private static let speedWidth: CGFloat = 26
    private static let gap: CGFloat = 6
    private static let barsWidth: CGFloat = 22
    static let totalWidth: CGFloat = margin + speedWidth + gap + barsWidth + margin

    private static let barHeight: CGFloat = 4
    private static let barGap: CGFloat = 2

    private var sample = StatsSample()

    override var isFlipped: Bool { true }

    // 点击穿透到 status item 的 button，由它触发弹窗
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ sample: StatsSample) {
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
        let x = Self.margin + Self.speedWidth + Self.gap
        let totalHeight = Self.barHeight * 3 + Self.barGap * 2
        var y = (bounds.height - totalHeight) / 2

        drawBar(x: x, y: y, usage: sample.cpuUsage, stroke: Self.tempColor(sample.cpuTemp))
        y += Self.barHeight + Self.barGap
        drawBar(x: x, y: y, usage: sample.gpuUsage, stroke: Self.tempColor(sample.gpuTemp))
        y += Self.barHeight + Self.barGap
        drawBar(x: x, y: y, usage: sample.ramUsage, stroke: nil)
    }

    private func drawBar(x: CGFloat, y: CGFloat, usage: Double, stroke: NSColor?) {
        let track = NSRect(x: x, y: y, width: Self.barsWidth, height: Self.barHeight)
        let radius = Self.barHeight / 2

        NSColor.labelColor.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

        let fillWidth = max(Self.barHeight, Self.barsWidth * min(max(usage, 0), 1))
        NSColor.labelColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fillWidth, height: Self.barHeight),
                     xRadius: radius, yRadius: radius).fill()

        if let stroke {
            stroke.setStroke()
            let path = NSBezierPath(roundedRect: track.insetBy(dx: -0.75, dy: -0.75),
                                    xRadius: radius + 0.75, yRadius: radius + 0.75)
            path.lineWidth = 1
            path.stroke()
        }
    }

    /// 温度 → 描边色；无温度数据时不描边
    static func tempColor(_ temp: Double?) -> NSColor? {
        guard let temp else { return nil }
        switch temp {
        case ..<60: return .systemGreen
        case ..<80: return .systemOrange
        default: return .systemRed
        }
    }
}
