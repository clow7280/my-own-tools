import Foundation

/// sparkline 的时间跨度：胶囊下拉三选一，弹窗系统页四张卡片各自持久化自己的档位。
/// rawValue 即窗口内的采样条数（采样间隔固定 1 秒），`allCases` 顺序即下拉菜单顺序。
public enum SparklineRange: Int, CaseIterable {
    case oneMinute = 60
    case fiveMinutes = 300
    case fifteenMinutes = 900

    /// 独立持久化档位的卡片。没有全局当前档位，切换某卡不影响其他卡。
    public enum Slot: String, CaseIterable {
        case usage, temperature, disk, network

        public var defaultsKey: String { "StatsSparklineRange." + rawValue }
    }

    /// 胶囊与下拉菜单项的文案
    public var caption: String {
        switch self {
        case .oneMinute: return "近 1 分钟"
        case .fiveMinutes: return "近 5 分钟"
        case .fifteenMinutes: return "近 15 分钟"
        }
    }

    /// 窗口内采样条数
    public var sampleCount: Int { rawValue }

    /// 每个绘制点合并多少条采样
    public var bucketSize: Int { Swift.max(1, sampleCount / SparklineDownsample.pointCapacity) }
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
public enum SparklineDownsample {
    /// 绘制点数固定 60：更长的时间跨度靠降采样成同样多的桶实现，
    /// 曲线密度与横向分辨率不随时长档位变化
    public static let pointCapacity = 60

    /// 带绝对序号的输入点；序号来自 StatsSample.sequence
    public typealias Point = (index: Int, value: Double)

    public static func average(_ points: [Point], range: SparklineRange) -> [Double] {
        buckets(points, range: range) { $0.reduce(0, +) / Double($0.count) }
    }

    public static func maximum(_ points: [Point], range: SparklineRange) -> [Double] {
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
