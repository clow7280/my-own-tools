import AppKit

/// 极简折线 sparkline：无背景无面积填充，数据右对齐（最新值贴右缘），
/// 不足容量时左侧留白。支持多系列叠画（网络卡片的下载/上传双线），系列共用量程。
final class SparklineView: NSView {
    struct Series {
        var values: [Double]
        var color: NSColor
        var lineWidth: CGFloat = 1.5
    }

    /// 纵轴量程
    enum Scale {
        case fixed(max: Double)         // 0~max（占用率）
        case autoMax(floor: Double)     // 0~峰值（速率类），floor 防微小波动被放大
        case band(padding: Double)      // 数据 min−p ~ max+p（温度，突出相对变化）
    }

    let capacity: Int
    var scale: Scale = .fixed(max: 1)

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
        guard capacity > 1, series.contains(where: { !$0.values.isEmpty }) else { return }

        let all = series.flatMap { $0.values.suffix(capacity) }
        let (low, high): (Double, Double)
        switch scale {
        case .fixed(let max):
            (low, high) = (0, max)
        case .autoMax(let floor):
            (low, high) = (0, Swift.max(all.max() ?? 0, floor))
        case .band(let padding):
            let lo = (all.min() ?? 0) - padding
            let hi = (all.max() ?? 0) + padding
            (low, high) = (lo, Swift.max(hi, lo + 1e-9))
        }
        let range = Swift.max(high - low, 1e-9)
        let rect = bounds.insetBy(dx: 1, dy: 1.5)

        for s in series where !s.values.isEmpty {
            let values = s.values.suffix(capacity)
            let startSlot = capacity - values.count
            var points: [NSPoint] = []
            for (i, v) in values.enumerated() {
                let x = rect.minX + rect.width * CGFloat(startSlot + i) / CGFloat(capacity - 1)
                let y = rect.minY + rect.height * CGFloat(min(max((v - low) / range, 0), 1))
                points.append(NSPoint(x: x, y: y))
            }
            let line = NSBezierPath()
            line.move(to: points[0])
            points.dropFirst().forEach { line.line(to: $0) }
            s.color.setStroke()
            line.lineWidth = s.lineWidth
            line.lineJoinStyle = .round
            line.lineCapStyle = .round
            line.stroke()
        }
    }
}
