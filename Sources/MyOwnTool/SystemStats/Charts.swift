import AppKit

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

    /// 绘制点数固定 60：更长的时间跨度靠降采样成同样多的桶实现，
    /// 曲线密度与横向分辨率不随时长档位变化
    static let pointCapacity = 60

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

/// sparkline 的时间跨度：胶囊下拉三选一，弹窗系统页四张卡片各自持久化自己的档位。
/// rawValue 即窗口内的采样条数（采样间隔固定 1 秒），`allCases` 顺序即下拉菜单顺序。
enum SparklineRange: Int, CaseIterable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    /// 独立持久化档位的卡片。没有全局当前档位，切换某卡不影响其他卡。
    enum Slot: String, CaseIterable {
        case usage, temperature, disk, network

        var defaultsKey: String { "StatsSparklineRange." + rawValue }
    }

    /// 读取某卡档位；未存值时默认近 1 分钟
    static func stored(_ slot: Slot) -> SparklineRange {
        SparklineRange(rawValue: UserDefaults.standard.integer(forKey: slot.defaultsKey)) ?? .oneMinute
    }

    static func store(_ range: SparklineRange, for slot: Slot) {
        UserDefaults.standard.set(range.rawValue, forKey: slot.defaultsKey)
    }

    /// 胶囊与下拉菜单项的文案
    var caption: String {
        switch self {
        case .oneMinute: return "近 1 分钟"
        case .fiveMinutes: return "近 5 分钟"
        case .fifteenMinutes: return "近 15 分钟"
        }
    }

    /// 窗口内采样条数
    var sampleCount: Int { rawValue }

    /// 每个绘制点合并多少条采样
    var bucketSize: Int { Swift.max(1, sampleCount / SparklineView.pointCapacity) }
}

/// 把 1 秒粒度的历史压成 sparkline 的绘制点。
///
/// 桶边界锚定采样的绝对序号：第 b 个桶固定覆盖序号 `[b*size, (b+1)*size)`，
/// 一条采样落进哪个桶只由它自己的序号决定，与窗口滑动无关。
/// 曾按窗口末尾往回切桶，窗口每秒滑一条会让所有桶边界相对数据移动一格，
/// 于是每个绘制点都变成滑动平均、整条曲线每秒重组一次，重组周期正好等于桶宽，
/// 5 分钟与 15 分钟档因此肉眼可见地周期性形变。
///
/// 最右一个桶是正在填充的部分桶，每来一条新采样就重算，桶满后曲线整体左移一格。
/// 历史不足时桶数变少，由 SparklineView 左侧留白；窗口跨桶边界时最左桶也可能不满，
/// 桶数会多出一个，交由 SparklineView 只取最后 `pointCapacity` 个点裁掉。
enum SparklineDownsample {
    /// 带绝对序号的输入点；序号来自 StatsSample.sequence
    typealias Point = (index: Int, value: Double)

    static func average(_ points: [Point], range: SparklineRange) -> [Double] {
        buckets(points, range: range) { $0.reduce(0, +) / Double($0.count) }
    }

    static func maximum(_ points: [Point], range: SparklineRange) -> [Double] {
        buckets(points, range: range) { $0.max() ?? 0 }
    }

    private static func buckets(_ points: [Point], range: SparklineRange,
                                combine: ([Double]) -> Double) -> [Double] {
        let window = points.suffix(range.sampleCount)
        guard let first = window.first else { return [] }
        let size = range.bucketSize
        guard size > 1 else { return window.map(\.value) }

        var result: [Double] = []
        var group: [Double] = []
        var current = first.index / size
        for point in window {
            let bucket = point.index / size
            if bucket != current {
                if !group.isEmpty { result.append(combine(group)) }
                group.removeAll(keepingCapacity: true)
                current = bucket
            }
            group.append(point.value)
        }
        if !group.isEmpty { result.append(combine(group)) }
        return result
    }
}
