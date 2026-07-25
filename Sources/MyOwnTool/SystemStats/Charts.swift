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

    /// 绘制点数固定 60：更长的时间跨度靠降采样成同样多的桶实现，
    /// 曲线密度与横向分辨率不随时长档位变化
    static let pointCapacity = 60

    let capacity: Int
    var scale: Scale = .fixed(max: 1)

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

/// sparkline 的时间跨度：三档循环切换，弹窗系统页四张卡片共享同一档并持久化。
/// rawValue 即窗口内的采样条数（采样间隔固定 1 秒）。
enum SparklineRange: Int {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    private static let defaultsKey = "StatsSparklineRange"

    /// 全局当前档位；UserDefaults 未写入或值非法时回落到 1 分钟
    static var current: SparklineRange {
        get { SparklineRange(rawValue: UserDefaults.standard.integer(forKey: defaultsKey)) ?? .oneMinute }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    /// 卡片标题行右侧的切换文案
    var caption: String {
        switch self {
        case .oneMinute: return "近 1 分钟"
        case .fiveMinutes: return "近 5 分钟"
        case .fifteenMinutes: return "近 15 分钟"
        }
    }

    var next: SparklineRange {
        switch self {
        case .oneMinute: return .fiveMinutes
        case .fiveMinutes: return .fifteenMinutes
        case .fifteenMinutes: return .oneMinute
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
