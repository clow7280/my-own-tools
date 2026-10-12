import Darwin
import Foundation
import StatsCore

@main
private enum StatsCoreChecks {
    static func main() {
        do {
            try self.checkMenuSpeed()
            try self.checkMenuSpeedWidthInvariant()
            try self.checkOtherFormats()
            try self.checkSparklineRange()
            try self.checkDownsampleBasics()
            try self.checkDownsampleAggregates()
            try self.checkDownsampleAbsoluteAnchoring()
            try self.checkTempTier()
            try self.checkLayoutDefaults()
            try self.checkLayoutZoneValidity()
            try self.checkLayoutNormalization()
            try self.checkLayoutSharedEdgeRounding()
            try self.checkLayoutEditRoundTrip()
            try self.checkLayoutAddRemoveDividers()
            try self.checkLayoutFocusRect()
            try self.checkLayoutRectangularSelection()
            try self.checkLayoutZoneRects()
            print("StatsCoreChecks: all checks passed")
        } catch {
            fputs("StatsCoreChecks failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    /// 菜单栏网速的各档边界。曾因 B 档过早进位把 10~49 B/s 显示成 "0.0K"，
    /// 非零速率被抹成 0，这里把每档的进位点与小数阈值都钉死。
    private static func checkMenuSpeed() throws {
        let cases: [(bps: Double, number: String, unit: String)] = [
            (-1, "0", "B"),
            (-1e9, "0", "B"),
            (0, "0", "B"),
            (10, "10", "B"),
            (49, "49", "B"),
            (999, "999", "B"),
            (999.4, "999", "B"),
            (999.5, "1.0", "K"),
            (1_000, "1.0", "K"),
            (9_949, "9.9", "K"),
            (9_950, "10", "K"),
            (999_499, "999", "K"),
            (999_500, "1.0", "M"),
            (1_200_000, "1.2", "M"),
            (999_499_999, "999", "M"),
            (999_500_000, "1.0", "G"),
            (1.2e9, "1.2", "G"),
        ]
        for item in cases {
            let (number, unit) = StatsFormat.menuSpeed(item.bps)
            try self.expect(
                number == item.number && unit == item.unit,
                "menuSpeed(\(item.bps)) 应为 \(item.number)\(item.unit)，实际 \(number)\(unit)")
        }
    }

    /// 菜单栏固定宽度不抖动的前提：数字部分恒不超过 3 字符。
    /// 上限取 G 档满量程之内，1 TB/s 以上的速率不在真实网卡范围。
    private static func checkMenuSpeedWidthInvariant() throws {
        var probes: [Double] = [-1e12, -1, 0]
        var scale = 1.0
        for _ in 0..<4 {
            for base in [1.0, 9.0, 9.949, 9.95, 10.0, 49.0, 99.9, 123.4, 500.0, 999.0, 999.4] {
                probes.append(base * scale)
            }
            scale *= 1_000
        }
        for bps in probes {
            let (number, unit) = StatsFormat.menuSpeed(bps)
            try self.expect(
                number.count <= 3,
                "menuSpeed(\(bps)) 的数字部分 \"\(number)\" 超过 3 字符")
            try self.expect(
                ["B", "K", "M", "G"].contains(unit),
                "menuSpeed(\(bps)) 的单位 \(unit) 不在 B/K/M/G 内")
        }
    }

    private static func checkOtherFormats() throws {
        try self.expect(StatsFormat.compactSpeed(999) == "999B", "compactSpeed 拼接数字与单位")
        try self.expect(StatsFormat.compactSpeed(1.2e9) == "1.2G", "compactSpeed G 档")

        try self.expect(StatsFormat.mbps(1_000_000) == "1.00", "mbps 两位小数档")
        try self.expect(StatsFormat.mbps(10_000_000) == "10.0", "mbps 一位小数档")
        try self.expect(StatsFormat.mbps(100_000_000) == "100", "mbps 整数档")

        try self.expect(StatsFormat.dataVolume(5e8) == "500 MB", "dataVolume MB 档")
        try self.expect(StatsFormat.dataVolume(1.5e9) == "1.5 GB", "dataVolume GB 档")
        try self.expect(StatsFormat.dataVolume(2.5e12) == "2.5 TB", "dataVolume TB 档")

        try self.expect(StatsFormat.percent(-0.5) == "0%", "percent 负值夹到 0")
        try self.expect(StatsFormat.percent(1.5) == "100%", "percent 超过 1 夹到 100")
        try self.expect(StatsFormat.percent(0.336) == "34%", "percent 四舍五入")

        try self.expect(StatsFormat.gigabytes(1_073_741_824) == "1.0", "gigabytes 取二进制口径")
    }

    /// 只覆盖纯换算与顺序。`stored` 与 `store` 读写 UserDefaults，
    /// 校验目标不污染用户 defaults，因此不在这里断言。
    private static func checkSparklineRange() throws {
        try self.expect(
            SparklineRange.allCases == [.oneMinute, .fiveMinutes, .fifteenMinutes],
            "allCases 顺序即下拉菜单顺序")
        try self.expect(
            SparklineRange.allCases.map(\.sampleCount) == [60, 300, 900],
            "sampleCount 即窗口内采样条数")
        try self.expect(
            SparklineRange.allCases.map(\.bucketSize) == [1, 5, 15],
            "bucketSize 即每个绘制点合并的采样条数")

        for range in SparklineRange.allCases {
            try self.expect(range.sampleCount == range.rawValue, "sampleCount 等于 rawValue")
            try self.expect(
                range.bucketSize
                    == Swift.max(1, range.sampleCount / SparklineDownsample.pointCapacity),
                "bucketSize 由 sampleCount 与 pointCapacity 换算")
            try self.expect(!range.caption.isEmpty, "每档都要有胶囊文案")
        }
        try self.expect(
            Set(SparklineRange.allCases.map(\.caption)).count == 3,
            "各档文案互不相同")

        try self.expect(
            SparklineRange.Slot.allCases.map(\.rawValue)
                == ["usage", "temperature", "disk", "network"],
            "四张卡的槽位与顺序")
        try self.expect(
            SparklineRange.Slot.usage.defaultsKey == "StatsSparklineRange.usage",
            "槽位的 defaults 键名前缀")
        try self.expect(
            Set(SparklineRange.Slot.allCases.map(\.defaultsKey)).count == 4,
            "槽位键名互不相同，各卡独立持久化")
    }

    private static func checkDownsampleBasics() throws {
        try self.expect(SparklineDownsample.pointCapacity == 60, "绘制点数固定 60")

        for range in SparklineRange.allCases {
            try self.expect(
                SparklineDownsample.average([], range: range).isEmpty,
                "空输入返回空（average，\(range.sampleCount) 秒档）")
            try self.expect(
                SparklineDownsample.maximum([], range: range).isEmpty,
                "空输入返回空（maximum，\(range.sampleCount) 秒档）")
        }

        // 1 分钟档 bucketSize 为 1，窗口内的采样原样返回，两种聚合退化成同一结果
        let minute = (0..<200).map { (index: $0, value: Double($0) * 0.5) }
        let raw = SparklineDownsample.average(minute, range: .oneMinute)
        try self.expect(raw == minute.suffix(60).map(\.value), "bucketSize 为 1 时原样返回窗口")
        try self.expect(
            SparklineDownsample.maximum(minute, range: .oneMinute) == raw,
            "bucketSize 为 1 时两种聚合结果一致")

        // 窗口对齐桶边界时，三档都正好降采样成 pointCapacity 个绘制点
        for range in SparklineRange.allCases {
            let aligned = (0..<range.sampleCount).map { (index: $0, value: Double($0)) }
            try self.expect(
                SparklineDownsample.average(aligned, range: range).count
                    == SparklineDownsample.pointCapacity,
                "\(range.sampleCount) 秒档对齐满窗口应得 60 个绘制点")
        }

        // 历史不足时桶数变少，由 SparklineView 左侧留白
        let short = (0..<45).map { (index: $0, value: Double($0)) }
        try self.expect(
            SparklineDownsample.average(short, range: .fiveMinutes).count == 9,
            "历史不足时桶数按已有序号缩减")
    }

    /// 取值以序号为数值，桶内均值与峰值都有闭式解
    private static func checkDownsampleAggregates() throws {
        let points = (0..<300).map { (index: $0, value: Double($0)) }
        let means = SparklineDownsample.average(points, range: .fiveMinutes)
        let peaks = SparklineDownsample.maximum(points, range: .fiveMinutes)
        try self.expect(means.count == 60 && peaks.count == 60, "5 分钟档桶数")
        for bucket in 0..<60 {
            try self.expect(means[bucket] == Double(5 * bucket + 2), "5 分钟档第 \(bucket) 桶均值")
            try self.expect(peaks[bucket] == Double(5 * bucket + 4), "5 分钟档第 \(bucket) 桶峰值")
        }

        let long = (0..<900).map { (index: $0, value: Double($0)) }
        let longMeans = SparklineDownsample.average(long, range: .fifteenMinutes)
        let longPeaks = SparklineDownsample.maximum(long, range: .fifteenMinutes)
        try self.expect(longMeans.count == 60 && longPeaks.count == 60, "15 分钟档桶数")
        for bucket in 0..<60 {
            try self.expect(
                longMeans[bucket] == Double(15 * bucket + 7),
                "15 分钟档第 \(bucket) 桶均值")
            try self.expect(
                longPeaks[bucket] == Double(15 * bucket + 14),
                "15 分钟档第 \(bucket) 桶峰值")
        }
    }

    /// 桶边界锚定绝对序号：窗口向前滑动不得改变已经填满的桶。
    /// 曾按窗口末尾往回切桶，窗口每滑一格所有桶边界跟着相对数据移动，
    /// 每个绘制点退化成滑动平均、整条曲线每秒重组一次，
    /// 5 与 15 分钟档因此肉眼可见地周期性形变。
    private static func checkDownsampleAbsoluteAnchoring() throws {
        // 对照序列起伏明显且与桶宽不同步，滑动平均不会碰巧等于分桶平均
        func value(_ index: Int) -> Double { Double((index &* 37) % 101) }

        for range in [SparklineRange.fiveMinutes, .fifteenMinutes] {
            let size = range.bucketSize
            let count = range.sampleCount

            // 末尾正好落在桶右边界，此时 60 个桶全满
            let alignedLast = 4 * count - 1
            let before = SparklineDownsample.average(
                (0...alignedLast).map { (index: $0, value: value($0)) }, range: range)
            let after = SparklineDownsample.average(
                (0...(alignedLast + 1)).map { (index: $0, value: value($0)) }, range: range)
            try self.expect(before.count == 60, "对齐窗口应得 60 个满桶（\(count) 秒档）")
            try self.expect(
                after.count == 61,
                "窗口滑过桶边界时最左桶不满，桶数多出一个（\(count) 秒档）")
            // 滑动后最左桶退化成部分桶、右端新开一个部分桶，中间 59 个满桶必须逐一原值保留
            try self.expect(
                Array(before[1...59]) == Array(after[1...59]),
                "窗口滑动一格后满桶取值必须不变（\(count) 秒档）")
            try self.expect(
                Set(before[1...59]).count > 1,
                "对照序列必须有起伏，否则上一条断言恒真（\(count) 秒档）")

            // 连续滑过两个桶宽，每个满桶的取值只由绝对序号决定
            for shift in 0...(2 * size) {
                let last = alignedLast + shift
                let history = (0...last).map { (index: $0, value: value($0)) }
                let means = SparklineDownsample.average(history, range: range)
                let peaks = SparklineDownsample.maximum(history, range: range)
                let firstIndex = last - count + 1
                let firstBucket = firstIndex / size
                let lastBucket = last / size
                try self.expect(
                    means.count == lastBucket - firstBucket + 1 && peaks.count == means.count,
                    "桶数等于窗口覆盖的绝对桶号个数（shift \(shift)，\(count) 秒档）")
                for bucket in firstBucket...lastBucket
                where bucket * size >= firstIndex && (bucket + 1) * size - 1 <= last {
                    let values = (bucket * size..<(bucket + 1) * size).map(value)
                    let mean = values.reduce(0, +) / Double(values.count)
                    try self.expect(
                        means[bucket - firstBucket] == mean,
                        "满桶均值只由绝对序号决定（桶 \(bucket)，shift \(shift)，\(count) 秒档）")
                    try self.expect(
                        peaks[bucket - firstBucket] == (values.max() ?? 0),
                        "满桶峰值只由绝对序号决定（桶 \(bucket)，shift \(shift)，\(count) 秒档）")
                }
            }
        }
    }

    /// 五档阈值与 DESIGN.md 的规范表格一一对应
    private static func checkTempTier() throws {
        try self.expect(TempTier(Double?.none) == nil, "温度缺失返回 nil")
        let cases: [(temp: Double, tier: TempTier)] = [
            (-40, .cool), (0, .cool), (44.9, .cool),
            (45, .warm), (59.9, .warm),
            (60, .hot), (74.9, .hot),
            (75, .searing), (89.9, .searing),
            (90, .critical), (150, .critical),
        ]
        for item in cases {
            try self.expect(
                TempTier(item.temp) == item.tier,
                "\(item.temp)℃ 应判为 \(item.tier)，实际 \(String(describing: TempTier(item.temp)))")
        }
    }

    // MARK: - 布局分区

    /// 分区比例落在 4 位小数网格上
    private static func onGrid(_ value: Double) -> Bool {
        abs(value * 10_000 - (value * 10_000).rounded()) < 1e-6
    }

    private static func defaultLayoutConfig() throws -> LayoutConfig {
        try JSONDecoder().decode(LayoutConfig.self, from: Data(LayoutConfig.defaultJSON.utf8))
    }

    /// 默认布局是校验失败时的兜底来源，它自己必须整组通过校验。
    /// 配置里写的是手写三位小数，0.6667 + 0.3333 与 0.3333 + 0.3334 这类加法一旦被判成越屏，
    /// 应用会把自带的布局丢个精光，拖拽时一个可吸附区域都没有。
    private static func checkLayoutDefaults() throws {
        let config = try self.defaultLayoutConfig()
        try self.expect(config.builtin.count == 2, "默认内置屏布局为左右两个半屏")
        try self.expect(config.external.count == 5, "默认外接屏布局为五分区")
        try self.expect(config.displays == nil, "默认配置不含具名显示器布局")
        try self.expect(
            LayoutGeometry.validZones(config.builtin) == config.builtin,
            "默认内置屏布局必须整组通过校验")
        try self.expect(
            LayoutGeometry.validZones(config.external) == config.external,
            "默认外接屏布局必须整组通过校验")

        // 默认布局本就落在 4 位小数网格上，归一化不该改动它，改动即说明取整口径变了
        let all = config.builtin + config.external
        let normalized = all.map { $0.normalizedForStorage() }
        try self.expect(normalized == all, "默认布局归一化后逐字不变")
        try self.expect(
            LayoutGeometry.validZones(normalized) == normalized,
            "默认布局归一化后仍整组合法")

        // 默认外接布局同轴相邻的分区共用同一条边，缝隙必须为 0
        try self.expect(
            config.external[0].x + config.external[0].w == config.external[1].x,
            "主区右边与右栏左边重合")
        try self.expect(
            config.external[0].y + config.external[0].h == config.external[2].y,
            "上排下边与底排上边重合")
    }

    /// 分区数值判定：这些矩形会经 Accessibility 直接套到别人的窗口上，
    /// 退化、越屏与非有限值都必须挡在写盘和吸附之前。
    private static func checkLayoutZoneValidity() throws {
        let eps = LayoutGeometry.ratioEpsilon
        try self.expect(eps == 1e-6, "比例容差固定 1e-6")
        try self.expect(LayoutGeometry.validZones([]).isEmpty, "空数组原样返回")

        let nan = Double.nan
        let rejected: [(name: String, zone: ZoneSpec)] = [
            ("零宽", ZoneSpec(x: 0.2, y: 0.2, w: 0, h: 0.5)),
            ("零高", ZoneSpec(x: 0.2, y: 0.2, w: 0.5, h: 0)),
            ("负宽", ZoneSpec(x: 0.5, y: 0.2, w: -0.3, h: 0.5)),
            ("负高", ZoneSpec(x: 0.2, y: 0.5, w: 0.5, h: -0.3)),
            ("负 x", ZoneSpec(x: -0.01, y: 0, w: 0.5, h: 0.5)),
            ("负 y", ZoneSpec(x: 0, y: -0.01, w: 0.5, h: 0.5)),
            ("x + w 越右边界", ZoneSpec(x: 0.5, y: 0, w: 0.6, h: 1)),
            ("y + h 越下边界", ZoneSpec(x: 0, y: 0.5, w: 1, h: 0.6)),
            ("x 为 NaN", ZoneSpec(x: nan, y: 0, w: 0.5, h: 0.5)),
            ("y 为 NaN", ZoneSpec(x: 0, y: nan, w: 0.5, h: 0.5)),
            ("w 为 NaN", ZoneSpec(x: 0, y: 0, w: nan, h: 0.5)),
            ("h 为 NaN", ZoneSpec(x: 0, y: 0, w: 0.5, h: nan)),
            ("x 为 +inf", ZoneSpec(x: .infinity, y: 0, w: 0.5, h: 0.5)),
            ("y 为 +inf", ZoneSpec(x: 0, y: .infinity, w: 0.5, h: 0.5)),
            ("w 为 +inf", ZoneSpec(x: 0, y: 0, w: .infinity, h: 0.5)),
            ("h 为 +inf", ZoneSpec(x: 0, y: 0, w: 0.5, h: .infinity)),
            ("x 为 -inf", ZoneSpec(x: -.infinity, y: 0, w: 0.5, h: 0.5)),
            ("y 为 -inf", ZoneSpec(x: 0, y: -.infinity, w: 0.5, h: 0.5)),
            ("w 为 -inf", ZoneSpec(x: 0, y: 0, w: -.infinity, h: 0.5)),
            ("h 为 -inf", ZoneSpec(x: 0, y: 0, w: 0.5, h: -.infinity)),
            // 容差边界的拒绝侧：宽高要严格大于容差，越界量要严格超出容差
            ("宽正好等于容差", ZoneSpec(x: 0, y: 0, w: eps, h: 0.5)),
            ("高正好等于容差", ZoneSpec(x: 0, y: 0, w: 0.5, h: eps)),
            ("x 负得超出容差", ZoneSpec(x: -1e-3, y: 0, w: 0.5, h: 0.5)),
            ("y 负得超出容差", ZoneSpec(x: 0, y: -1e-3, w: 0.5, h: 0.5)),
            ("x + w 超出容差", ZoneSpec(x: 0.5, y: 0, w: 0.5 + 1e-3, h: 1)),
            ("y + h 超出容差", ZoneSpec(x: 0, y: 0.5, w: 1, h: 0.5 + 1e-3)),
        ]
        for item in rejected {
            try self.expect(
                LayoutGeometry.validZones([item.zone]).isEmpty,
                "\(item.name) 的分区必须被剔除")
        }

        let accepted: [(name: String, zone: ZoneSpec)] = [
            ("普通分区", ZoneSpec(name: "基准", x: 0.25, y: 0.25, w: 0.5, h: 0.5)),
            ("满屏", ZoneSpec(x: 0, y: 0, w: 1, h: 1)),
            ("贴右下角", ZoneSpec(x: 0.6667, y: 0.6667, w: 0.3333, h: 0.3333)),
            // 容差边界的通过侧：舍入误差量级的越界要被吸收，否则手写小数的布局会被误杀
            ("宽略大于容差", ZoneSpec(x: 0, y: 0, w: 2 * eps, h: 0.5)),
            ("高略大于容差", ZoneSpec(x: 0, y: 0, w: 0.5, h: 2 * eps)),
            ("x 负在容差内", ZoneSpec(x: -1e-7, y: 0, w: 0.5, h: 0.5)),
            ("y 负在容差内", ZoneSpec(x: 0, y: -1e-7, w: 0.5, h: 0.5)),
            ("x + w 越界在容差内", ZoneSpec(x: 0.5, y: 0, w: 0.5 + 1e-7, h: 1)),
            ("y + h 越界在容差内", ZoneSpec(x: 0, y: 0.5, w: 1, h: 0.5 + 1e-7)),
        ]
        for item in accepted {
            try self.expect(
                LayoutGeometry.validZones([item.zone]) == [item.zone],
                "\(item.name) 的分区必须保留")
        }

        // 单个坏分区只丢它自己，其余保持原顺序
        let good = accepted.map(\.zone)
        let mixed = [good[0], rejected[0].zone, good[1], rejected[8].zone, good[2]]
        try self.expect(
            LayoutGeometry.validZones(mixed) == [good[0], good[1], good[2]],
            "只丢非法分区且保序")
        try self.expect(
            LayoutGeometry.validZones(rejected.map(\.zone)).isEmpty,
            "整组非法时返回空数组，交由调用方回落默认布局")
    }

    /// 写回前的归一化：4 位小数、边界夹取，以及与校验之间的契约。
    private static func checkLayoutNormalization() throws {
        let messy = ZoneSpec(name: "拖拽结果", x: 0.4166666666666667, y: 0.123456789,
                             w: 0.2777777777777778, h: 0.333333333)
        let tidy = messy.normalizedForStorage()
        try self.expect(tidy.name == "拖拽结果", "归一化保留分区名")
        try self.expect(tidy.x == 0.4167, "左边取整到 0.4167，实际 \(tidy.x)")
        try self.expect(tidy.w == 0.2777, "宽由取整后的边相减得到 0.2777，实际 \(tidy.w)")
        try self.expect(tidy.y == 0.1235, "上边取整到 0.1235，实际 \(tidy.y)")
        try self.expect(tidy.h == 0.3333, "高由取整后的边相减得到 0.3333，实际 \(tidy.h)")

        // clamp01：越界的边被夹回可用区域，尺寸随之缩短
        let leftOut = ZoneSpec(x: -0.2, y: -0.35, w: 0.5, h: 0.5).normalizedForStorage()
        try self.expect(leftOut.x == 0 && leftOut.y == 0, "负起点夹到 0")
        try self.expect(leftOut.w == 0.3, "左侧越界的宽缩到 0.3，实际 \(leftOut.w)")
        try self.expect(leftOut.h == 0.15, "上侧越界的高缩到 0.15，实际 \(leftOut.h)")
        let rightOut = ZoneSpec(x: 0.8, y: 0.9, w: 0.5, h: 0.4).normalizedForStorage()
        try self.expect(rightOut.x == 0.8 && rightOut.y == 0.9, "起点在界内时不动")
        try self.expect(rightOut.w == 0.2, "右侧越界的宽缩到 0.2，实际 \(rightOut.w)")
        try self.expect(rightOut.h == 0.1, "下侧越界的高缩到 0.1，实际 \(rightOut.h)")
        try self.expect(
            LayoutGeometry.validZones([leftOut, rightOut]) == [leftOut, rightOut],
            "夹取后的分区仍然合法")

        // 整块落在可用区域之外时归一化只会得到退化分区，救不回来的交给校验拦下
        let outside = ZoneSpec(x: -0.6, y: 0.2, w: 0.4, h: 0.4).normalizedForStorage()
        try self.expect(outside.w == 0, "完全在左界外的分区宽被夹成 0")
        try self.expect(LayoutGeometry.validZones([outside]).isEmpty, "退化分区由校验剔除")

        // 归一化与校验的契约：输入落在可用区域内且宽高不退化时，
        // 归一化结果必然仍能通过校验，用户拖完的布局不会被下一次 load() 丢掉。
        // 顺带钉住 4 位小数与幂等：归一化两次与一次结果完全相同
        for i in 0..<40 {
            for j in 0..<40 {
                let x = Double(i) / 40 * 0.97 + 0.00013
                let y = Double(j) / 40 * 0.97 + 0.00017
                let w = (1 - x) * (0.05 + Double((i * 7 + j) % 19) / 20)
                let h = (1 - y) * (0.05 + Double((i * 11 + j * 3) % 17) / 18)
                let zone = ZoneSpec(name: "扫描\(i)-\(j)", x: x, y: y, w: w, h: h)
                let once = zone.normalizedForStorage()
                try self.expect(
                    LayoutGeometry.validZones([once]) == [once],
                    "归一化结果必须通过校验（\(zone)）")
                try self.expect(
                    self.onGrid(once.x) && self.onGrid(once.y)
                        && self.onGrid(once.w) && self.onGrid(once.h),
                    "归一化结果落在 4 位小数网格上（\(once)）")
                try self.expect(once.normalizedForStorage() == once, "归一化幂等（\(once)）")
            }
        }
    }

    /// 按「边」取整而不是按「尺寸」取整：相邻分区共用同一条边，取整结果相同才不留缝、不越界。
    /// 0.66665 / 0.33335 这类正落在 4 位小数进位点上的分割，
    /// 按尺寸取整会得到 0.6667 + 0.3334 = 1.0001，超出容差一百倍，
    /// 用户刚拖完的布局下一次 load() 就被整个丢掉。
    private static func checkLayoutSharedEdgeRounding() throws {
        let eps = LayoutGeometry.ratioEpsilon
        let leftHalf = ZoneSpec(name: "左", x: 0, y: 0, w: 0.66665, h: 1).normalizedForStorage()
        let rightHalf = ZoneSpec(name: "右", x: 0.66665, y: 0, w: 0.33335, h: 1).normalizedForStorage()
        try self.expect(leftHalf.w == 0.6667, "左分区右边进位到 0.6667，实际 \(leftHalf.w)")
        try self.expect(rightHalf.x == 0.6667, "右分区左边与左分区右边取整结果相同，实际 \(rightHalf.x)")
        try self.expect(
            rightHalf.w == 0.3333,
            "右分区宽由边相减得到 0.3333，按尺寸取整则是 0.3334，实际 \(rightHalf.w)")
        try self.expect(rightHalf.x + rightHalf.w <= 1 + eps, "右分区不越界")
        try self.expect(
            0.6667 + 0.3334 > 1 + eps,
            "按尺寸取整的 0.6667 + 0.3334 确实超出容差，上一条断言不是恒真")

        // 把上面这一个定点扩成整条进位线：分割点全部落在 .00005 上，
        // 两侧分区共用同一条边，取整后既不许留缝也不许把 x+w 顶出容差
        for k in 500...9_500 {
            let split = (Double(k) + 0.5) / 10_000
            let head = ZoneSpec(x: 0, y: 0, w: split, h: 1).normalizedForStorage()
            let tail = ZoneSpec(x: split, y: 0, w: 1 - split, h: 1).normalizedForStorage()
            try self.expect(
                abs(head.x + head.w - tail.x) <= 1e-12,
                "分割点 \(split) 两侧不留缝隙，实际差 \(head.x + head.w - tail.x)")
            try self.expect(
                tail.x + tail.w <= 1 + eps,
                "分割点 \(split) 的右分区不越界，实际 \(tail.x + tail.w)")
            try self.expect(
                LayoutGeometry.validZones([head, tail]) == [head, tail],
                "分割点 \(split) 两侧分区都合法")
        }
    }

    /// 分割线反复拖动的往返稳定性：上一轮的归一化结果作为下一轮输入，
    /// 误差不得随编辑次数累积，否则几十次拖动之后 x+w 漂出容差、布局在重启后消失。
    /// 移动序列固定不用随机数，失败可原样复现。
    private static func checkLayoutEditRoundTrip() throws {
        let eps = LayoutGeometry.ratioEpsilon
        let minSize = 0.05
        // 竖分割改 x/w，横分割改 y/h，两条路径共用同一套算术
        let axes: [(name: String, start: WritableKeyPath<ZoneSpec, Double>,
                    size: WritableKeyPath<ZoneSpec, Double>)] = [
            ("竖分割", \.x, \.w),
            ("横分割", \.y, \.h),
        ]
        for axis in axes {
            var specs = (0..<4).map { index -> ZoneSpec in
                var zone = ZoneSpec(name: "分区\(index)", x: 0, y: 0, w: 1, h: 1)
                zone[keyPath: axis.start] = Double(index) / 4
                zone[keyPath: axis.size] = 0.25
                return zone
            }
            var visited: Set<Double> = []
            for round in 0..<500 {
                let index = 1 + round % 3               // 轮流移动 3 条内部分割线
                // 固定步长序列，幅度约 ±0.014，且刻意不落在 4 位小数网格上
                let delta = Double((round &* 37) % 101 - 50) / 3_571
                let lower = specs[index - 1][keyPath: axis.start] + minSize
                let upper = specs[index][keyPath: axis.start]
                    + specs[index][keyPath: axis.size] - minSize
                var coordinate = min(max(specs[index][keyPath: axis.start] + delta, lower), upper)
                // 每隔一轮把分割线挪到 4 位小数的进位点上（形如 0.66665）。
                // 这正是按尺寸取整会翻车的位置，按边取整必须连着扛住 250 轮
                if round % 2 == 1 {
                    let tie = ((coordinate * 10_000).rounded(.down) + 0.5) / 10_000
                    coordinate = min(max(tie, lower), upper)
                }
                // 与 LayoutEditController 拖动分割线时同一套更新：前一区改尺寸，后一区改起点并补尺寸
                specs[index - 1][keyPath: axis.size] =
                    coordinate - specs[index - 1][keyPath: axis.start]
                let end = specs[index][keyPath: axis.start] + specs[index][keyPath: axis.size]
                specs[index][keyPath: axis.start] = coordinate
                specs[index][keyPath: axis.size] = end - coordinate
                specs = specs.map { $0.normalizedForStorage() }
                visited.insert(specs[index][keyPath: axis.start])

                let tag = "\(axis.name)第 \(round) 轮"
                try self.expect(
                    LayoutGeometry.validZones(specs) == specs,
                    "\(tag)：四个分区必须全部合法")
                try self.expect(
                    specs[0][keyPath: axis.start] == 0,
                    "\(tag)：首个分区仍贴住起始边")
                let last = specs[3]
                try self.expect(
                    abs(last[keyPath: axis.start] + last[keyPath: axis.size] - 1) <= 1e-12,
                    "\(tag)：末尾分区仍贴住结束边，实际 "
                        + "\(last[keyPath: axis.start] + last[keyPath: axis.size])")
                try self.expect(
                    last[keyPath: axis.start] + last[keyPath: axis.size] <= 1 + eps,
                    "\(tag)：末尾分区不越界")
                for i in 0..<3 {
                    let gap = specs[i][keyPath: axis.start] + specs[i][keyPath: axis.size]
                        - specs[i + 1][keyPath: axis.start]
                    try self.expect(abs(gap) <= 1e-12, "\(tag)：第 \(i) 与 \(i + 1) 区之间缝隙 \(gap)")
                }
                for spec in specs {
                    try self.expect(
                        self.onGrid(spec[keyPath: axis.start]) && self.onGrid(spec[keyPath: axis.size]),
                        "\(tag)：比例仍落在 4 位小数网格上（\(spec)）")
                    try self.expect(
                        spec[keyPath: axis.size] >= minSize - 1e-4,
                        "\(tag)：没有分区被挤到最小尺寸以下（\(spec)）")
                }
            }
            // 分割线必须真的在动，否则上面几百轮断言只是把同一个状态重复检查了几百遍
            try self.expect(
                visited.count > 50,
                "\(axis.name)：分割线只停在 \(visited.count) 个位置，移动序列没有覆盖足够多的取整场景")
        }
    }

    /// 编辑器新增与删除线段的纯几何契约：分割后不退化，T 形边删除后不重叠也不留洞。
    private static func checkLayoutAddRemoveDividers() throws {
        let whole = [ZoneSpec(name: "工作区", x: 0, y: 0, w: 1, h: 1)]
        guard let vertical = LayoutGeometry.splitting(
            whole, zoneAt: 0, axis: .vertical, coordinate: 0.4) else {
            throw CheckFailure("整屏分区应能增加竖分割线")
        }
        try self.expect(vertical.count == 2, "竖分割产生两个分区")
        try self.expect(
            vertical[0] == ZoneSpec(name: "工作区·左", x: 0, y: 0, w: 0.4, h: 1)
                && vertical[1] == ZoneSpec(name: "工作区·右", x: 0.4, y: 0, w: 0.6, h: 1),
            "竖分割保留覆盖范围并追加方向名称")

        guard let clamped = LayoutGeometry.splitting(
            whole, zoneAt: 0, axis: .horizontal, coordinate: 0.01) else {
            throw CheckFailure("靠近边缘的横分割应夹到最小尺寸")
        }
        try self.expect(clamped[0].h == 0.1 && clamped[1].y == 0.1, "横分割两端至少保留 10%")
        try self.expect(
            LayoutGeometry.splitting(
                [ZoneSpec(x: 0, y: 0, w: 0.19, h: 1)],
                zoneAt: 0, axis: .vertical, coordinate: 0.1) == nil,
            "宽度不足两个最小分区时拒绝新增竖线")

        guard let merged = LayoutGeometry.removingDividerSegment(
            from: vertical, axis: .vertical, coordinate: 0.4, crossCoordinate: 0.5) else {
            throw CheckFailure("简单竖分割应能删除")
        }
        try self.expect(merged.count == 1, "删除简单竖线后恢复单分区")
        try self.expect(
            merged[0].x == 0 && merged[0].y == 0 && merged[0].w == 1 && merged[0].h == 1,
            "删除简单竖线后覆盖整屏")
        try self.expect(merged[0].name == "工作区", "新增后立即删除应恢复原分区名称")

        // 上方一个大区、下方两个小区。删除左半段横线时，先把上方大区沿 x=0.5 拆开，
        // 再将左上与左下合并；右半段横线仍保留。
        let tee = [
            ZoneSpec(name: "上", x: 0, y: 0, w: 1, h: 0.5),
            ZoneSpec(name: "下左", x: 0, y: 0.5, w: 0.5, h: 0.5),
            ZoneSpec(name: "下右", x: 0.5, y: 0.5, w: 0.5, h: 0.5),
        ]
        guard let withoutLeftSegment = LayoutGeometry.removingDividerSegment(
            from: tee, axis: .horizontal, coordinate: 0.5, crossCoordinate: 0.25) else {
            throw CheckFailure("T 形连接的左半段横线应能删除")
        }
        try self.expect(withoutLeftSegment.count == 3, "T 形线段删除后仍为三个矩形")
        try self.expect(
            withoutLeftSegment.contains {
                $0.x == 0 && $0.y == 0 && $0.w == 0.5 && $0.h == 1
            },
            "左上与左下合并成全高左区")
        try self.expect(
            withoutLeftSegment.contains {
                $0.x == 0.5 && $0.y == 0 && $0.w == 0.5 && $0.h == 0.5
            } && withoutLeftSegment.contains {
                $0.x == 0.5 && $0.y == 0.5 && $0.w == 0.5 && $0.h == 0.5
            },
            "右半段横线及其上下分区保持不变")
        let covered = withoutLeftSegment.reduce(0.0) { $0 + $1.w * $1.h }
        try self.expect(abs(covered - 1) < 1e-12, "删除 T 形线段后总覆盖率仍为 100%")
        for (index, lhs) in withoutLeftSegment.enumerated() {
            for rhs in withoutLeftSegment.dropFirst(index + 1) {
                let overlapWidth = min(lhs.x + lhs.w, rhs.x + rhs.w) - max(lhs.x, rhs.x)
                let overlapHeight = min(lhs.y + lhs.h, rhs.y + rhs.h) - max(lhs.y, rhs.y)
                try self.expect(
                    overlapWidth <= 1e-12 || overlapHeight <= 1e-12,
                    "删除 T 形线段后分区不得重叠")
                }
        }

        try self.expect(
            LayoutGeometry.removingDividerSegment(
                from: tee, axis: .horizontal, coordinate: 0.5, crossCoordinate: 0.5) == nil,
            "指针正落在 T 形交点时不得猜测要删除哪一段")
        let gapped = [
            ZoneSpec(x: 0, y: 0, w: 0.498, h: 1),
            ZoneSpec(x: 0.502, y: 0, w: 0.498, h: 1),
        ]
        try self.expect(
            LayoutGeometry.removingDividerSegment(
                from: gapped, axis: .vertical, coordinate: 0.5, crossCoordinate: 0.5) == nil,
            "聚类成同一视觉线的近邻分区若实际有缝隙，不得直接合并并填掉缝隙")

        try self.expect(
            LayoutGeometry.removingDividerSegment(
                from: whole, axis: .vertical, coordinate: 0.5, crossCoordinate: 0.5) == nil,
            "没有相邻边时拒绝删除")
    }

    private static func checkLayoutFocusRect() throws {
        try self.expect(
            LayoutGeometry.focusWidthRatio == 2.0 / 3.0
                && LayoutGeometry.focusHeightRatio == 2.0 / 3.0,
            "专注布局宽高比例固定为可用区域的 2/3")

        let area = CGRect(x: -300, y: 100, width: 1200, height: 900)
        try self.expect(
            LayoutGeometry.focusRect(in: area)
                == CGRect(x: -100, y: 250, width: 800, height: 600),
            "专注布局在非零原点可用区域内按固定比例居中")

        // 1512 × 945 是常见的 MacBook 缩放后逻辑尺寸，结果只由目标显示器决定。
        let macBookArea = CGRect(x: 0, y: 0, width: 1512, height: 945)
        try self.expect(
            LayoutGeometry.focusRect(in: macBookArea)
                == CGRect(x: 252, y: 157.5, width: 1008, height: 630),
            "MacBook 逻辑可用区域得到稳定的 1008 × 630 pt 专注窗口")
    }

    /// Option 经过多个分区时，窗口目标必须仍是由现有分区完整铺成的单个矩形。
    private static func checkLayoutRectangularSelection() throws {
        let area = CGRect(x: -120, y: 80, width: 1200, height: 900)
        let external = try self.defaultLayoutConfig().external
        let rects = LayoutGeometry.rects(for: external, in: area)

        let repeated = LayoutGeometry.rectangularSelection(in: rects, including: [2, 2])
        try self.expect(
            repeated == RectangularZoneSelection(indices: [2], rect: rects[2]),
            "重复经过同一分区不改变单分区目标")

        // 主区与底左构成 L 形；最小外包矩形内的底中会自动补入，得到完整的左侧 2/3。
        let left = LayoutGeometry.rectangularSelection(in: rects, including: [0, 2])
        try self.expect(left?.indices == [0, 2, 3], "L 形路径补齐外包矩形内的必要分区")
        let expectedLeft = CGRect(x: area.minX, y: area.minY,
                                  width: area.width * 0.6667, height: area.height)
        let leftOffsets = left.map {
            [abs($0.rect.minX - expectedLeft.minX), abs($0.rect.minY - expectedLeft.minY),
             abs($0.rect.maxX - expectedLeft.maxX), abs($0.rect.maxY - expectedLeft.maxY)]
        } ?? [.infinity]
        try self.expect(
            leftOffsets.allSatisfy { $0 <= 1e-6 },
            "补齐后目标为全高左侧 2/3")

        let whole = LayoutGeometry.rectangularSelection(in: rects, including: [0, 4])
        try self.expect(whole?.indices == Array(rects.indices), "跨对角经过时补齐整屏五个分区")
        let wholeOffsets = whole.map {
            [abs($0.rect.minX - area.minX), abs($0.rect.minY - area.minY),
             abs($0.rect.maxX - area.maxX), abs($0.rect.maxY - area.maxY)]
        } ?? [.infinity]
        try self.expect(
            wholeOffsets.allSatisfy { $0 <= 1e-6 },
            "五个分区完整铺满可用区域")

        let gapped = [
            CGRect(x: 0, y: 0, width: 49, height: 100),
            CGRect(x: 51, y: 0, width: 49, height: 100),
        ]
        try self.expect(
            LayoutGeometry.rectangularSelection(in: gapped, including: [0, 1]) == nil,
            "有空洞的分区不能组合成窗口矩形")

        let overlapping = [
            CGRect(x: 0, y: 0, width: 60, height: 100),
            CGRect(x: 40, y: 0, width: 60, height: 100),
        ]
        try self.expect(
            LayoutGeometry.rectangularSelection(in: overlapping, including: [0, 1]) == nil,
            "互相重叠的分区不能组合成窗口矩形")

        let crossing = [
            CGRect(x: 0, y: 0, width: 50, height: 100),
            CGRect(x: 40, y: 0, width: 20, height: 100),
        ]
        try self.expect(
            LayoutGeometry.rectangularSelection(in: crossing, including: [0]) == nil,
            "未选分区切进目标内部时拒绝有歧义的组合")
        try self.expect(
            LayoutGeometry.rectangularSelection(in: rects, including: [-1]) == nil
                && LayoutGeometry.rectangularSelection(in: rects, including: [rects.count]) == nil,
            "越界分区索引不能产生目标")

        let nearSeam = [
            CGRect(x: 0, y: 0, width: 50, height: 100),
            CGRect(x: 50.0000005, y: 0, width: 49.9999995, height: 100),
        ]
        try self.expect(
            LayoutGeometry.rectangularSelection(in: nearSeam, including: [0, 1])?.rect
                == CGRect(x: 0, y: 0, width: 100, height: 100),
            "浮点容差内的接缝仍视作连续")
    }

    /// 比例到矩形的换算，重点是纵向翻转：配置的 y 原点在左上，Cocoa 在左下。
    private static func checkLayoutZoneRects() throws {
        // 原点取非零值，漏掉 area.minX / area.minY 会立刻暴露
        let area = CGRect(x: 100, y: 200, width: 1600, height: 900)

        try self.expect(
            LayoutGeometry.rect(for: ZoneSpec(x: 0, y: 0, w: 1, h: 1), in: area) == area,
            "整屏分区即可用区域本身")
        try self.expect(LayoutGeometry.rects(for: [], in: area).isEmpty, "空分区表得到空矩形表")

        let top = LayoutGeometry.rect(for: ZoneSpec(x: 0, y: 0, w: 1, h: 0.5), in: area)
        let bottom = LayoutGeometry.rect(for: ZoneSpec(x: 0, y: 0.5, w: 1, h: 0.5), in: area)
        try self.expect(
            top == CGRect(x: 100, y: 650, width: 1600, height: 450),
            "上半屏矩形，实际 \(top)")
        try self.expect(
            bottom == CGRect(x: 100, y: 200, width: 1600, height: 450),
            "下半屏矩形，实际 \(bottom)")
        // 纵向翻转写反时下面三条会同时失败
        try self.expect(top.minY > bottom.minY, "配置 y 越大，Cocoa 原点越低")
        try self.expect(top.maxY == area.maxY, "y 为 0 的分区顶边与可用区域顶边重合")
        try self.expect(bottom.minY == area.minY, "y + h 为 1 的分区底边与可用区域底边重合")

        let quarter = LayoutGeometry.rect(for: ZoneSpec(x: 0.5, y: 0.25, w: 0.5, h: 0.25), in: area)
        try self.expect(
            quarter == CGRect(x: 900, y: 650, width: 800, height: 225),
            "右侧偏上的四分之一区，实际 \(quarter)")

        // 默认外接布局套进可用区域：主区贴左上，底排三格贴底边，五格铺满且互不重叠
        let external = try self.defaultLayoutConfig().external
        let rects = LayoutGeometry.rects(for: external, in: area)
        try self.expect(rects.count == 5, "五分区换算出五个矩形")
        try self.expect(
            rects == external.map { LayoutGeometry.rect(for: $0, in: area) },
            "批量换算与逐个换算结果一致")
        try self.expect(
            abs(rects[0].minX - area.minX) < 1e-9 && abs(rects[0].maxY - area.maxY) < 1e-9,
            "主区贴住可用区域左上角，实际 \(rects[0])")
        try self.expect(
            abs(rects[0].width - area.width * 0.6667) < 1e-9,
            "主区宽度按比例缩放，实际 \(rects[0].width)")
        try self.expect(
            abs(rects[1].maxX - area.maxX) < 1e-9,
            "右栏贴住可用区域右边，实际 \(rects[1])")
        for index in 2...4 {
            try self.expect(
                abs(rects[index].minY - area.minY) < 1e-9,
                "底排第 \(index - 1) 格贴住底边，实际 \(rects[index])")
        }
        let covered = rects.reduce(0.0) { $0 + $1.width * $1.height }
        let total = area.width * area.height
        try self.expect(
            abs(covered - total) / total < 1e-3,
            "五分区铺满可用区域且互不重叠，覆盖率 \(covered / total)")

        // 可用区域换一块，矩形随之整体平移与缩放
        let moved = CGRect(x: -500, y: -300, width: 800, height: 450)
        let half = LayoutGeometry.rect(for: ZoneSpec(x: 0.5, y: 0, w: 0.5, h: 1), in: moved)
        try self.expect(
            half == CGRect(x: -100, y: -300, width: 400, height: 450),
            "负原点区域上的右半屏，实际 \(half)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message) }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
