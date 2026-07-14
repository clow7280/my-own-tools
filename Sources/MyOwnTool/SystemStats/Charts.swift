import AppKit

/// 简单的多系列面积折线图：数据右对齐（最新值贴右边），不足 capacity 时左侧留白
final class LineChartView: NSView {
    struct Series {
        var values: [Double]
        var color: NSColor
    }

    let capacity: Int
    /// 纵轴最大值；nil 表示按数据峰值自动缩放
    var fixedMax: Double? = 1
    /// 自动量程时的最小上限，防止微小波动被放大
    var autoMaxFloor: Double = 0
    /// 自动量程时右上角的峰值标注文本
    var peakFormatter: ((Double) -> String)?

    private var series: [Series] = []

    init(capacity: Int) {
        self.capacity = capacity
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ series: [Series]) {
        self.series = series
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard capacity > 1, series.contains(where: { !$0.values.isEmpty }) else { return }

        let peak = series.flatMap(\.values).max() ?? 0
        let maxValue = fixedMax ?? max(peak, autoMaxFloor, 1e-9)
        let rect = bounds.insetBy(dx: 3, dy: 3)

        for s in series where !s.values.isEmpty {
            let values = s.values.suffix(capacity)
            let startSlot = capacity - values.count
            var points: [NSPoint] = []
            for (i, v) in values.enumerated() {
                let x = rect.minX + rect.width * CGFloat(startSlot + i) / CGFloat(capacity - 1)
                let y = rect.minY + rect.height * CGFloat(min(max(v / maxValue, 0), 1))
                points.append(NSPoint(x: x, y: y))
            }

            let line = NSBezierPath()
            line.move(to: points[0])
            points.dropFirst().forEach { line.line(to: $0) }
            s.color.withAlphaComponent(0.9).setStroke()
            line.lineWidth = 1.5
            line.lineJoinStyle = .round
            line.stroke()

            if points.count > 1 {
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: points[points.count - 1].x, y: rect.minY))
                area.line(to: NSPoint(x: points[0].x, y: rect.minY))
                area.close()
                s.color.withAlphaComponent(0.15).setFill()
                area.fill()
            }
        }

        if fixedMax == nil, let text = peakFormatter?(max(peak, autoMaxFloor)) {
            Charts.drawCaption(text, at: NSPoint(x: bounds.maxX - 6, y: bounds.maxY - 4),
                               anchor: .topRight, in: bounds)
        }
    }
}

/// 上下镜像面积图（仿 Stats 网络负载历史）：中线以上为上传、以下为下载，
/// 两半各自独立量程，峰值分别标注在左上/左下角
final class MirrorChartView: NSView {
    let capacity: Int
    var upColor = NSColor.systemRed
    var downColor = NSColor.systemBlue
    /// 每半边自动量程的最小上限
    var autoMaxFloor: Double = 50_000

    private var up: [Double] = []
    private var down: [Double] = []

    init(capacity: Int) {
        self.capacity = capacity
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(up: [Double], down: [Double]) {
        self.up = up
        self.down = down
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        guard capacity > 1 else { return }

        let rect = bounds.insetBy(dx: 3, dy: 3)
        let midY = rect.midY

        // 中线
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        let mid = NSBezierPath()
        mid.move(to: NSPoint(x: rect.minX, y: midY))
        mid.line(to: NSPoint(x: rect.maxX, y: midY))
        mid.lineWidth = 1
        mid.stroke()

        let halfHeight = rect.height / 2 - 1
        drawHalf(up, color: upColor, rect: rect, midY: midY, halfHeight: halfHeight, upward: true)
        drawHalf(down, color: downColor, rect: rect, midY: midY, halfHeight: halfHeight, upward: false)

        let upPeak = max(up.suffix(capacity).max() ?? 0, autoMaxFloor)
        let downPeak = max(down.suffix(capacity).max() ?? 0, autoMaxFloor)
        Charts.drawCaption("\(StatsFormat.speed(upPeak))/s",
                           at: NSPoint(x: bounds.minX + 6, y: bounds.maxY - 4), anchor: .topLeft, in: bounds)
        Charts.drawCaption("\(StatsFormat.speed(downPeak))/s",
                           at: NSPoint(x: bounds.minX + 6, y: bounds.minY + 4), anchor: .bottomLeft, in: bounds)
    }

    private func drawHalf(_ values: [Double], color: NSColor, rect: NSRect,
                          midY: CGFloat, halfHeight: CGFloat, upward: Bool) {
        let window = values.suffix(capacity)
        guard !window.isEmpty else { return }
        let maxValue = max(window.max() ?? 0, autoMaxFloor, 1e-9)
        let startSlot = capacity - window.count
        let sign: CGFloat = upward ? 1 : -1

        var points: [NSPoint] = []
        for (i, v) in window.enumerated() {
            let x = rect.minX + rect.width * CGFloat(startSlot + i) / CGFloat(capacity - 1)
            let y = midY + sign * halfHeight * CGFloat(min(max(v / maxValue, 0), 1))
            points.append(NSPoint(x: x, y: y))
        }

        let line = NSBezierPath()
        line.move(to: points[0])
        points.dropFirst().forEach { line.line(to: $0) }
        color.withAlphaComponent(0.9).setStroke()
        line.lineWidth = 1
        line.stroke()

        let area = line.copy() as! NSBezierPath
        area.line(to: NSPoint(x: points[points.count - 1].x, y: midY))
        area.line(to: NSPoint(x: points[0].x, y: midY))
        area.close()
        color.withAlphaComponent(0.25).setFill()
        area.fill()
    }
}

/// 图表内小字标注的共用绘制
enum Charts {
    enum Anchor { case topLeft, topRight, bottomLeft }

    static func drawCaption(_ text: String, at point: NSPoint, anchor: Anchor, in bounds: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let label = NSAttributedString(string: text, attributes: attrs)
        let size = label.size()
        var origin: NSPoint
        switch anchor {
        case .topLeft: origin = NSPoint(x: point.x, y: point.y - size.height)
        case .topRight: origin = NSPoint(x: point.x - size.width, y: point.y - size.height)
        case .bottomLeft: origin = NSPoint(x: point.x, y: point.y)
        }
        label.draw(at: origin)
    }
}
