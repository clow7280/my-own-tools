import AppKit
import StatsCore

/// 菜单栏内容视图，从左到右两块（DESIGN.md「菜单栏常驻区」）：
/// 网速两行数字（上=上传 下=下载）| CPU/GPU/RAM 竖柱。
/// 竖柱从底向上填充指标色，1pt 边框按温度分级着色（CPU/GPU 取自身温度，RAM 取硬盘温度），
/// ≥90℃ 以 1.1s 周期闪烁并带红色光晕。
/// 固定总宽避免数字跳动引起菜单栏抖动；作为 button 子视图自动跟随菜单栏明暗。
final class StatsBarView: NSView {
    // MARK: - 布局常量（对齐设计稿 1× 尺寸）

    private static let margin: CGFloat = 3
    /// 内容整体右移的像素：从右边距借出，不改变总宽
    private static let contentOffset: CGFloat = 4
    private static let contentLeft: CGFloat = margin + contentOffset
    private static let blockGap: CGFloat = 7

    private static let speedFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    private static let speedLineHeight: CGFloat = 11.5
    /// 数字右对齐区宽 = 3 个等宽字符
    private static let speedNumberWidth: CGFloat = ceil(("888" as NSString).size(withAttributes: [.font: speedFont]).width)
    private static let speedUnitWidth: CGFloat = ceil(("M" as NSString).size(withAttributes: [.font: speedFont]).width)
    private static let speedWidth: CGFloat = speedNumberWidth + 0.5 + speedUnitWidth

    private static let barFillWidth: CGFloat = 7
    private static let barFillHeight: CGFloat = 17
    private static let barGap: CGFloat = 3.5
    /// 填充圆角随柱宽同比微调，边框圆角始终为它加 0.5 以与 -0.5 外扩同心
    private static let barFillRadius: CGFloat = 2.5
    private static let barBorderRadius: CGFloat = barFillRadius + 0.5
    /// 单柱视觉宽（含 1pt 边框）
    private static let barVisualWidth: CGFloat = barFillWidth + 2
    private static let barsWidth: CGFloat = barVisualWidth * 3 + barGap * 2

    static let totalWidth: CGFloat = margin + speedWidth + blockGap + barsWidth + margin

    // MARK: - 数据

    private var sample = StatsSample()

    // ≥90℃ 紧急档边框以 1.1s 周期闪烁
    private var blinkTimer: Timer?
    private var blinkOn = true

    override var isFlipped: Bool { true }

    // 点击穿透到 status item 的 button，由它触发弹窗
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(_ sample: StatsSample) {
        self.sample = sample
        updateBlinkTimer()
        needsDisplay = true
    }

    /// 任一柱进入紧急档时以 0.55s 半周期闪烁；恢复后停表
    private func updateBlinkTimer() {
        let emergency = [sample.cpuTemp, sample.gpuTemp, sample.diskTemp]
            .contains { TempTier($0) == .critical }
        if emergency, blinkTimer == nil {
            let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.needsDisplay = true
                }
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
    }

    // MARK: - 网速

    private func drawSpeed() {
        // 上下两行同用标签色：次级色在菜单栏上可读性差（DESIGN.md 2026-07-18）
        let top = (bounds.height - Self.speedLineHeight * 2) / 2
        drawSpeedLine(sample.netUp, color: .labelColor, lineTop: top)
        drawSpeedLine(sample.netDown, color: .labelColor, lineTop: top + Self.speedLineHeight)
    }

    private func drawSpeedLine(_ bps: Double, color: NSColor, lineTop: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.speedFont, .foregroundColor: color]
        let (number, unit) = StatsFormat.menuSpeed(bps)
        let numberText = NSAttributedString(string: number, attributes: attrs)
        let unitText = NSAttributedString(string: unit, attributes: attrs)
        let y = lineTop + (Self.speedLineHeight - numberText.size().height) / 2
        numberText.draw(at: NSPoint(x: Self.contentLeft + Self.speedNumberWidth - numberText.size().width, y: y))
        unitText.draw(at: NSPoint(x: Self.contentLeft + Self.speedNumberWidth + 0.5, y: y))
    }

    // MARK: - 竖柱

    private func drawBars() {
        var x = Self.contentLeft + Self.speedWidth + Self.blockGap
        let fillTop = (bounds.height - Self.barFillHeight) / 2

        drawBar(x: x, y: fillTop, usage: sample.cpuUsage, fill: StatsPalette.cpu, tier: TempTier(sample.cpuTemp))
        x += Self.barVisualWidth + Self.barGap
        drawBar(x: x, y: fillTop, usage: sample.gpuUsage, fill: StatsPalette.gpu, tier: TempTier(sample.gpuTemp))
        x += Self.barVisualWidth + Self.barGap
        // RAM 柱边框取硬盘温度（DESIGN.md 温度分级）
        drawBar(x: x, y: fillTop, usage: sample.ramUsage, fill: StatsPalette.ram, tier: TempTier(sample.diskTemp))
    }

    /// 竖柱：轨道 + 从底向上填充（flipped 坐标系下即从 maxY 往上）+ 温度分级边框
    private func drawBar(x: CGFloat, y: CGFloat, usage: Double, fill: NSColor, tier: TempTier?) {
        let track = NSRect(x: x + 1, y: y, width: Self.barFillWidth, height: Self.barFillHeight)
        let trackPath = NSBezierPath(roundedRect: track,
                                     xRadius: Self.barFillRadius, yRadius: Self.barFillRadius)

        StatsPalette.barTrack.setFill()
        trackPath.fill()

        // 填充裁剪进轨道圆角内，避免低占用时溢出圆角
        let fillHeight = max(1, Self.barFillHeight * min(max(usage, 0), 1))
        NSGraphicsContext.current?.saveGraphicsState()
        trackPath.addClip()
        fill.setFill()
        NSRect(x: track.minX, y: track.maxY - fillHeight,
               width: Self.barFillWidth, height: fillHeight).fill()
        NSGraphicsContext.current?.restoreGraphicsState()

        guard let tier else { return }
        let border = NSBezierPath(roundedRect: track.insetBy(dx: -0.5, dy: -0.5),
                                  xRadius: Self.barBorderRadius, yRadius: Self.barBorderRadius)
        border.lineWidth = 1
        if tier == .critical {
            // 闪烁：亮拍全强度 + 红色光晕，暗拍压低透明度
            NSGraphicsContext.current?.saveGraphicsState()
            if blinkOn {
                let shadow = NSShadow()
                shadow.shadowColor = NSColor(srgbRed: 1, green: 45 / 255, blue: 85 / 255, alpha: 0.85)
                shadow.shadowBlurRadius = 3
                shadow.set()
                tier.border.setStroke()
            } else {
                tier.border.withAlphaComponent(0.35).setStroke()
            }
            border.stroke()
            NSGraphicsContext.current?.restoreGraphicsState()
        } else {
            tier.border.setStroke()
            border.stroke()
        }
    }

}
