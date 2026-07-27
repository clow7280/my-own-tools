import AppKit
import StatsCore

/// 档位的持久化留在 UI 侧：`StatsCore` 只放能离线校验的纯逻辑，
/// 校验目标一旦链接进读写 UserDefaults 的代码，跑测试就会污染用户的真实偏好。
extension SparklineRange {
    /// 读取某卡档位；未存值时默认近 1 分钟
    static func stored(_ slot: Slot) -> SparklineRange {
        SparklineRange(rawValue: UserDefaults.standard.integer(forKey: slot.defaultsKey)) ?? .oneMinute
    }

    static func store(_ range: SparklineRange, for slot: Slot) {
        UserDefaults.standard.set(range.rawValue, forKey: slot.defaultsKey)
    }
}

/// 极简折线 sparkline：无背景无面积填充，无刻度线也无边框，数据右对齐（最新值贴右缘），
/// 不足容量时左侧留白。支持多系列叠画（网络卡片的下载/上传双线）。
///
/// 纵轴量程取当前窗口内全部系列绘制点的最小值到最大值，曲线纵向填满绘图区：
/// 固定 0~1 或 0~峰值的量程会把空闲期压成贴底的直线，看不出起伏。
/// 绝对读数由绘图区右侧的刻度列补回，上下各标一个当前窗口的最值（DESIGN.md「弹窗」）。
final class SparklineView: NSView {
    struct Series {
        var values: [Double]
        var color: NSColor
        var lineWidth: CGFloat = 1.5
    }

    /// 右侧刻度列的数值格式，按卡片类型选择
    enum ScaleFormat {
        case percent    // 0~1 占用率 → "87%"
        case celsius    // ℃ → "72°"
        case rate       // 字节/秒 → "312M"

        func text(_ value: Double) -> String {
            switch self {
            case .percent: return StatsFormat.percent(value)
            case .celsius: return String(format: "%.0f°", value)
            case .rate: return StatsFormat.compactSpeed(value)
            }
        }
    }

    /// 绘制点数固定 60，定义在 StatsCore 的 SparklineDownsample，
    /// 降采样与绘制共用同一个常量
    static let pointCapacity = SparklineDownsample.pointCapacity

    /// 右侧刻度列占用的宽度，含与曲线之间的间距；视图自身的宽度不变，缩窄的是绘图区
    static let scaleColumnWidth: CGFloat = 34
    private static let scaleGap: CGFloat = 4
    private static let scaleFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)

    let capacity: Int
    var scaleFormat: ScaleFormat = .percent

    private var series: [Series] = []

    init(capacity: Int = pointCapacity) {
        self.capacity = capacity
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(_ series: [Series]) {
        self.series = series
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let area = bounds.insetBy(dx: 1, dy: 1.5)
        let plot = NSRect(x: area.minX, y: area.minY,
                          width: Swift.max(area.width - Self.scaleColumnWidth, 1),
                          height: area.height)
        guard capacity > 1, plot.height > 0 else { return }

        // 量程与刻度都取实际绘制的降采样点，多系列共用
        let all = series.flatMap { $0.values.suffix(capacity) }
        guard let low = all.min(), let high = all.max() else { return }
        let span = high - low

        for s in series where !s.values.isEmpty {
            let values = s.values.suffix(capacity)
            let startSlot = capacity - values.count
            var points: [NSPoint] = []
            for (i, v) in values.enumerated() {
                let x = plot.minX + plot.width * CGFloat(startSlot + i) / CGFloat(capacity - 1)
                // 全部点相等（如磁盘长时间空闲）时量程退化，统一画在垂直中线而不是贴底
                let fraction = span > 1e-9 ? CGFloat((v - low) / span) : 0.5
                points.append(NSPoint(x: x, y: plot.minY + plot.height * fraction))
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

        drawScale(low: low, high: high, in: plot)
    }

    /// 绘图区右侧的最值刻度：上缘最大值、下缘最小值，与曲线填满的上下边一一对应。
    /// 两行左对齐贴着曲线，四张卡一致。
    private func drawScale(low: Double, high: Double, in plot: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.scaleFont,
            .foregroundColor: NSColor.labelColor,
        ]
        let x = plot.maxX + Self.scaleGap
        let width = Swift.max(bounds.maxX - 1 - x, 0)
        let lineHeight = ceil(Self.scaleFont.ascender - Self.scaleFont.descender)
        guard width > 0, plot.height >= lineHeight else { return }
        NSAttributedString(string: scaleFormat.text(high), attributes: attributes)
            .draw(in: NSRect(x: x, y: plot.maxY - lineHeight, width: width, height: lineHeight))
        NSAttributedString(string: scaleFormat.text(low), attributes: attributes)
            .draw(in: NSRect(x: x, y: plot.minY, width: width, height: lineHeight))
    }
}
