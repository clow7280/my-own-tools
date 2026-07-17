import AppKit

/// 菜单栏内容视图，从左到右三块（DESIGN.md「菜单栏常驻区」）：
/// 网速两行数字（上=上传次级色 下=下载标签色）| CPU/GPU/RAM 竖柱 | ChatGPT/Claude 双层用量环。
/// 竖柱从底向上填充指标色，1pt 边框按温度分级着色（CPU/GPU 取自身温度，RAM 取硬盘温度），
/// ≥90℃ 以 1.1s 周期闪烁并带红色光晕。
/// 环外圈 = 5 小时窗口标准色，内圈 = 7 天窗口弱化色；5 小时限额取消时外圈画品牌色虚点圆。
/// 固定总宽避免数字跳动引起菜单栏抖动；作为 button 子视图自动跟随菜单栏明暗。
final class StatsBarView: NSView {
    // MARK: - 布局常量（对齐设计稿 1× 尺寸）

    private static let margin: CGFloat = 3
    /// 内容整体右移的像素：从右边距借出，不改变总宽
    private static let contentOffset: CGFloat = 4
    private static let contentLeft: CGFloat = margin + contentOffset
    private static let blockGap: CGFloat = 7

    private static let speedFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
    private static let speedLineHeight: CGFloat = 10.5
    /// 数字右对齐区宽 = 3 个等宽字符
    private static let speedNumberWidth: CGFloat = ceil(("888" as NSString).size(withAttributes: [.font: speedFont]).width)
    private static let speedUnitWidth: CGFloat = ceil(("M" as NSString).size(withAttributes: [.font: speedFont]).width)
    private static let speedWidth: CGFloat = speedNumberWidth + 0.5 + speedUnitWidth

    private static let barFillWidth: CGFloat = 6
    private static let barFillHeight: CGFloat = 16
    private static let barGap: CGFloat = 3.5
    /// 单柱视觉宽（含 1pt 边框）
    private static let barVisualWidth: CGFloat = barFillWidth + 2
    private static let barsWidth: CGFloat = barVisualWidth * 3 + barGap * 2

    private static let ringDiameter: CGFloat = 18
    private static let ringGap: CGFloat = 6
    private static let ringsWidth: CGFloat = ringDiameter * 2 + ringGap
    private static let ringOuterRadius: CGFloat = 7.8
    private static let ringInnerRadius: CGFloat = 4.4
    private static let ringLineWidth: CGFloat = 2.4

    static let totalWidth: CGFloat = margin + speedWidth + blockGap + barsWidth
        + blockGap + ringsWidth + margin

    // MARK: - 数据

    private var sample = StatsSample()
    private var chatGPTUsage: AIUsage?
    private var claudeUsage: AIUsage?

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

    func updateAIUsage(chatGPT: AIUsage?, claude: AIUsage?) {
        chatGPTUsage = chatGPT
        claudeUsage = claude
        needsDisplay = true
    }

    /// 任一柱进入紧急档时以 0.55s 半周期闪烁；恢复后停表
    private func updateBlinkTimer() {
        let emergency = [sample.cpuTemp, sample.gpuTemp, sample.diskTemp]
            .contains { TempTier($0) == .critical }
        if emergency, blinkTimer == nil {
            let timer = Timer(timeInterval: 0.55, repeats: true) { [weak self] _ in
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
        drawRings()
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
        let trackPath = NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2)

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
        let border = NSBezierPath(roundedRect: track.insetBy(dx: -0.5, dy: -0.5), xRadius: 2.5, yRadius: 2.5)
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

    // MARK: - AI 用量环

    private func drawRings() {
        let x = Self.contentLeft + Self.speedWidth + Self.blockGap + Self.barsWidth + Self.blockGap
        let cy = bounds.height / 2
        drawRing(center: NSPoint(x: x + Self.ringDiameter / 2, y: cy), usage: chatGPTUsage,
                 standard: StatsPalette.chatGPT, dim: StatsPalette.chatGPTDim)
        drawRing(center: NSPoint(x: x + Self.ringDiameter * 1.5 + Self.ringGap, y: cy), usage: claudeUsage,
                 standard: StatsPalette.claude, dim: StatsPalette.claudeDim)
    }

    /// 双层环：外 5h 标准色 / 内 7d 弱化色；5h 限额取消（无 5h 但有 7d）时外圈画虚点圆
    private func drawRing(center: NSPoint, usage: AIUsage?, standard: NSColor, dim: NSColor) {
        if let five = usage?.fiveHour {
            drawCircle(center: center, radius: Self.ringOuterRadius, color: StatsPalette.ringTrack)
            drawArc(center: center, radius: Self.ringOuterRadius, fraction: five, color: standard)
        } else if usage?.sevenDay != nil {
            drawDottedCircle(center: center, radius: Self.ringOuterRadius, color: standard)
        } else {
            drawCircle(center: center, radius: Self.ringOuterRadius, color: StatsPalette.ringTrack)
        }

        drawCircle(center: center, radius: Self.ringInnerRadius, color: StatsPalette.ringTrack)
        if let seven = usage?.sevenDay {
            drawArc(center: center, radius: Self.ringInnerRadius, fraction: seven, color: dim)
        }
    }

    private func drawCircle(center: NSPoint, radius: CGFloat, color: NSColor) {
        let path = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                               width: radius * 2, height: radius * 2))
        path.lineWidth = Self.ringLineWidth
        color.setStroke()
        path.stroke()
    }

    /// 从视觉 12 点方向顺时针画进度弧（flipped 坐标系下角度递增即视觉顺时针）
    private func drawArc(center: NSPoint, radius: CGFloat, fraction: Double, color: NSColor) {
        let clamped = min(max(fraction, 0), 1)
        guard clamped > 0.001 else { return }
        let path = NSBezierPath()
        path.appendArc(withCenter: center, radius: radius,
                       startAngle: -90, endAngle: -90 + 360 * clamped, clockwise: false)
        path.lineWidth = Self.ringLineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// 5 小时限额取消状态：品牌色圆点虚线圆。
    /// 逐点显式绘制而非 setLineDash：dash 周期不能整除圆周长时，路径首尾处圆点会粘连
    private func drawDottedCircle(center: NSPoint, radius: CGFloat, color: NSColor) {
        let dotRadius: CGFloat = 1
        let count = max(8, Int((2 * CGFloat.pi * radius / 3.5).rounded()))
        color.withAlphaComponent(0.75).setFill()
        for i in 0..<count {
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
            let dot = NSPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            NSBezierPath(ovalIn: NSRect(x: dot.x - dotRadius, y: dot.y - dotRadius,
                                        width: dotRadius * 2, height: dotRadius * 2)).fill()
        }
    }
}
