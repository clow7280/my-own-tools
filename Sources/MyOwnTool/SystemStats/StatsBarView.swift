import AppKit

/// 菜单栏内容视图：网速两行数字（上=上传 下=下载）| CPU/GPU/RAM 竖向进度条 | AI 用量横条。
/// 竖条从底向上填充 DESIGN.md 指标色；CPU/GPU 描边四档表示温度
/// （<45℃ 无、黄 45~60、橙 60~75、红 75~90、紫 >90 且闪烁）。
/// AI 横条（上=ChatGPT 下=Claude）显示 5 小时用量，数据未接入时只画轨道。
/// 固定总宽避免数字跳动引起菜单栏抖动；作为 button 子视图自动跟随菜单栏明暗。
final class StatsBarView: NSView {
    // 布局常量：[边距][网速块][间距][竖条块][间距][AI 横条块][边距]
    private static let margin: CGFloat = 4
    private static let speedWidth: CGFloat = 26
    private static let gap: CGFloat = 6
    private static let barsWidth: CGFloat = barWidth * 3 + barGap * 2
    static let totalWidth: CGFloat = margin + speedWidth + gap + barsWidth + gap + aiWidth + margin

    private static let barWidth: CGFloat = 4
    private static let barHeight: CGFloat = 16
    private static let barGap: CGFloat = 4

    // AI 5 小时用量横条（上=ChatGPT 下=Claude），数据未接入时只画轨道
    private static let aiWidth: CGFloat = 22
    private static let aiBarHeight: CGFloat = 4
    private static let aiBarGap: CGFloat = 2

    /// 单次采样间变化量超过该值时，该条提亮一拍以突出突发活动
    private static let highlightDelta = 0.3

    private var sample = StatsSample()
    private var previous = StatsSample()

    /// AI 5h 用量（0~1），nil = 未接入数据
    private var openAIUsage: Double?
    private var claudeUsage: Double?

    // >90℃ 紧急档描边闪烁
    private var blinkTimer: Timer?
    private var blinkOn = true

    override var isFlipped: Bool { true }

    // 点击穿透到 status item 的 button，由它触发弹窗
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ sample: StatsSample) {
        previous = self.sample
        self.sample = sample
        updateBlinkTimer()
        needsDisplay = true
    }

    /// 将来接入 Codex/Claude 订阅数据后调用
    func updateAIUsage(openAI: Double?, claude: Double?) {
        openAIUsage = openAI
        claudeUsage = claude
        needsDisplay = true
    }

    /// 任一温度超过 90℃ 时以 0.5s 周期闪烁描边；恢复后停表
    private func updateBlinkTimer() {
        let emergency = max(sample.cpuTemp ?? 0, sample.gpuTemp ?? 0) > 90
        if emergency, blinkTimer == nil {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.blinkOn.toggle()
                self.needsDisplay = true
            }
            RunLoop.main.add(timer, forMode: .common)
            blinkTimer = timer
        } else if !emergency, let timer = blinkTimer {
            timer.invalidate()
            blinkTimer = nil
            blinkOn = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        drawSpeed()
        drawBars()
        drawAIBars()
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
                stroke: strokeColor(for: sample.cpuTemp),
                highlight: abs(sample.cpuUsage - previous.cpuUsage) > Self.highlightDelta)
        x += Self.barWidth + Self.barGap
        drawBar(x: x, y: y, usage: sample.gpuUsage, fill: StatsPalette.gpu,
                stroke: strokeColor(for: sample.gpuTemp),
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

    /// 温度 → 警示描边色（四档）；常温（<45℃）与无数据时不描边，保持安静
    static func tempColor(_ temp: Double?) -> NSColor? {
        guard let temp else { return nil }
        switch temp {
        case ..<45: return nil
        case ..<60: return .systemYellow
        case ..<75: return .systemOrange
        case ..<90: return .systemRed
        default: return .systemPurple
        }
    }

    /// 紧急档（>90℃ 紫色）随 blinkOn 闪烁，其余档常亮
    private func strokeColor(for temp: Double?) -> NSColor? {
        guard let color = Self.tempColor(temp) else { return nil }
        if let temp, temp > 90, !blinkOn { return nil }
        return color
    }

    // MARK: - AI 用量横条（预留）

    private func drawAIBars() {
        let x = Self.margin + Self.speedWidth + Self.gap + Self.barsWidth + Self.gap
        let blockHeight = Self.aiBarHeight * 2 + Self.aiBarGap
        var y = (bounds.height - blockHeight) / 2

        drawAIBar(x: x, y: y, usage: openAIUsage, fill: StatsPalette.openAI)
        y += Self.aiBarHeight + Self.aiBarGap
        drawAIBar(x: x, y: y, usage: claudeUsage, fill: StatsPalette.claude)
    }

    /// 横向进度条：从左向右填充；usage 为 nil（未接入）时只画轨道
    private func drawAIBar(x: CGFloat, y: CGFloat, usage: Double?, fill: NSColor) {
        let radius = Self.aiBarHeight / 2
        NSColor.labelColor.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: Self.aiWidth, height: Self.aiBarHeight),
                     xRadius: radius, yRadius: radius).fill()

        guard let usage else { return }
        let fillWidth = max(Self.aiBarHeight, Self.aiWidth * min(max(usage, 0), 1))
        fill.setFill()
        NSBezierPath(roundedRect: NSRect(x: x, y: y, width: fillWidth, height: Self.aiBarHeight),
                     xRadius: radius, yRadius: radius).fill()
    }
}
