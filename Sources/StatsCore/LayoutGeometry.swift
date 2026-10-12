import CoreGraphics

/// 单个分区。坐标为屏幕可用区域内的比例值（0~1），原点在左上角。
public struct ZoneSpec: Codable, Equatable {
    public var name: String?
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(name: String? = nil, x: Double, y: Double, w: Double, h: Double) {
        self.name = name
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

extension ZoneSpec {
    /// 分割线编辑写回前的归一化：比例值收敛到 4 位小数，且保证 x+w、y+h 不越过 1。
    ///
    /// 拖拽算出的原始 Double 直接写盘有两个麻烦。
    /// 一是 0.4166666666666667 这种值原样落进配置文件，用户之后再想手改就无从下手。
    /// 二是每次编辑只重算分割线相邻的那几个分区，误差会一路累加，
    /// 几轮之后 x+w 可能漂到 1+1e-5 这类超出 LayoutStore 容差的数值，
    /// 下一次 load() 就把用户刚拖出来的分区当越屏分区丢掉。
    ///
    /// 所以按「边」而不是按「尺寸」取整：左右两条边各自夹进 0...1 再取 4 位小数，
    /// 尺寸由取整后的边相减得到。相邻分区共用同一条边、取整结果也相同，
    /// 缝隙和越界都不会随编辑次数累积。
    /// NaN 与 ±inf 会原样穿过这里，交给 LayoutStore 的数值校验拦截。
    public func normalizedForStorage() -> ZoneSpec {
        func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
        func clamp01(_ value: Double) -> Double { min(max(value, 0), 1) }
        let left = round4(clamp01(x))
        let top = round4(clamp01(y))
        let right = round4(clamp01(x + w))
        let bottom = round4(clamp01(y + h))
        return ZoneSpec(name: name, x: left, y: top,
                        w: round4(right - left), h: round4(bottom - top))
    }
}

public struct LayoutConfig: Codable {
    /// 内置显示器（MacBook 屏幕）布局
    public var builtin: [ZoneSpec]
    /// 外接显示器默认布局
    public var external: [ZoneSpec]
    /// 按显示器名称（系统设置中显示的名称）指定布局，优先级最高
    public var displays: [String: [ZoneSpec]]?

    /// 默认配置：内置屏左右对半；外接屏为「主区 + 右栏 + 底部三格」。
    public static let defaultJSON = """
    {
      "builtin": [
        { "name": "左半屏", "x": 0,   "y": 0, "w": 0.5, "h": 1 },
        { "name": "右半屏", "x": 0.5, "y": 0, "w": 0.5, "h": 1 }
      ],
      "external": [
        { "name": "1·主区", "x": 0,      "y": 0,      "w": 0.6667, "h": 0.6667 },
        { "name": "2·右栏", "x": 0.6667, "y": 0,      "w": 0.3333, "h": 0.6667 },
        { "name": "A·底左", "x": 0,      "y": 0.6667, "w": 0.3333, "h": 0.3333 },
        { "name": "B·底中", "x": 0.3333, "y": 0.6667, "w": 0.3334, "h": 0.3333 },
        { "name": "C·底右", "x": 0.6667, "y": 0.6667, "w": 0.3333, "h": 0.3333 }
      ]
    }
    """
}

public enum LayoutAxis: Equatable {
    case vertical
    case horizontal
}

/// 多个配置分区共同组成的矩形目标。
public struct RectangularZoneSelection: Equatable {
    public let indices: [Int]
    public let rect: CGRect

    public init(indices: [Int], rect: CGRect) {
        self.indices = indices
        self.rect = rect
    }
}

/// 分区的纯几何：数值合法性判定与比例到矩形的换算。
/// 可用区域由调用方以矩形传入，这里不碰 NSScreen，无显示器环境也能校验。
public enum LayoutGeometry {
    /// 比例值比较的容差。
    /// 配置里的比例是手写的三位小数，0.6667 + 0.3333 这类加法在 Double 里未必正好等于 1，
    /// 严格按 <= 1 判定会把默认布局自己判成越屏；1e-6 折算到 4K 宽度不足 0.01 像素，
    /// 既能吸收舍入误差，也不会放过真正越界的数值。
    public static let ratioEpsilon = 1e-6

    /// 剔除会让 zoneRects 算出退化或越屏矩形的分区。
    /// 这些矩形会经 Accessibility 直接套到其他 App 的窗口上，宁可丢弃也不能放行。
    public static func validZones(_ zones: [ZoneSpec]) -> [ZoneSpec] {
        zones.filter { zone in
            // NaN 与 ±inf 参与比较时所有判定都会失效，必须先挡掉
            guard zone.x.isFinite, zone.y.isFinite, zone.w.isFinite, zone.h.isFinite else { return false }
            // 容差内视作等于 0 或等于 1：宽高不得退化，起点不得为负，右下角不得越出可用区域
            guard zone.w > ratioEpsilon, zone.h > ratioEpsilon else { return false }
            guard zone.x >= -ratioEpsilon, zone.y >= -ratioEpsilon else { return false }
            return zone.x + zone.w <= 1 + ratioEpsilon && zone.y + zone.h <= 1 + ratioEpsilon
        }
    }

    /// 分区在可用区域内的矩形。
    /// 配置的 y 原点在左上、Cocoa 在左下，纵向要翻转一次，横向直接按比例落位。
    public static func rect(for spec: ZoneSpec, in area: CGRect) -> CGRect {
        CGRect(
            x: area.minX + area.width * spec.x,
            y: area.minY + area.height * (1 - spec.y - spec.h),
            width: area.width * spec.w,
            height: area.height * spec.h
        )
    }

    public static func rects(for specs: [ZoneSpec], in area: CGRect) -> [CGRect] {
        specs.map { rect(for: $0, in: area) }
    }

    /// 把经过的分区扩展成一个能由现有分区完整铺满的最小矩形。
    ///
    /// requiredIndices 是用户明确经过的分区；它们的外包矩形里若还有完整落入的分区，
    /// 会作为填满矩形所必需的连续空间一并返回。空洞、面积重叠或只切进矩形一部分的分区
    /// 都会令组合失败，避免把不可表达的 L 形目标直接套到矩形窗口上。
    public static func rectangularSelection(
        in rects: [CGRect],
        including requiredIndices: [Int],
        tolerance: CGFloat = 1e-6
    ) -> RectangularZoneSelection? {
        guard tolerance.isFinite, tolerance >= 0, !requiredIndices.isEmpty else { return nil }

        var seen = Set<Int>()
        let required = requiredIndices.filter { index in
            rects.indices.contains(index) && seen.insert(index).inserted
        }
        guard required.count == Set(requiredIndices).count,
              required.allSatisfy({ valid(rects[$0], tolerance: tolerance) }),
              let first = required.first else { return nil }

        let bounds = required.dropFirst().reduce(rects[first].standardized) {
            $0.union(rects[$1].standardized)
        }
        let included = rects.indices.filter {
            valid(rects[$0], tolerance: tolerance)
                && contains(bounds, rect: rects[$0].standardized, tolerance: tolerance)
        }

        // 未被纳入的分区若切进目标内部，说明配置本身在这里有重叠，不能把它当成连续矩形。
        let includedSet = Set(included)
        for index in rects.indices where !includedSet.contains(index) {
            let rect = rects[index].standardized
            guard valid(rect, tolerance: tolerance) else { continue }
            let overlap = bounds.intersection(rect)
            if !overlap.isNull && overlap.width > tolerance && overlap.height > tolerance {
                return nil
            }
        }

        guard rectangularUnion(rects: included.map { rects[$0].standardized },
                               bounds: bounds, tolerance: tolerance) else { return nil }
        return RectangularZoneSelection(indices: included, rect: bounds)
    }

    /// 专注布局固定占目标显示器可用区域的 2/3，避免尺寸继承自拖动前所在的分区。
    public static let focusWidthRatio: CGFloat = 2.0 / 3.0
    public static let focusHeightRatio: CGFloat = 2.0 / 3.0

    public static func focusRect(in area: CGRect) -> CGRect {
        let size = CGSize(
            width: max(area.width, 0) * focusWidthRatio,
            height: max(area.height, 0) * focusHeightRatio)
        return CGRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height)
    }

    private static func valid(_ rect: CGRect, tolerance: CGFloat) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > tolerance && rect.height > tolerance
    }

    private static func contains(_ outer: CGRect, rect inner: CGRect, tolerance: CGFloat) -> Bool {
        inner.minX >= outer.minX - tolerance && inner.maxX <= outer.maxX + tolerance
            && inner.minY >= outer.minY - tolerance && inner.maxY <= outer.maxY + tolerance
    }

    /// 以所有矩形边界切成小格，每格必须恰好被一个分区覆盖。
    /// 单看面积相等无法排除「一处重叠、另一处空洞」刚好抵消的情况。
    private static func rectangularUnion(rects: [CGRect], bounds: CGRect, tolerance: CGFloat) -> Bool {
        guard !rects.isEmpty, valid(bounds, tolerance: tolerance) else { return false }

        func clustered(_ values: [CGFloat]) -> [CGFloat] {
            values.sorted().reduce(into: []) { result, value in
                guard let last = result.last, abs(last - value) <= tolerance else {
                    result.append(value)
                    return
                }
            }
        }

        let xs = clustered([bounds.minX, bounds.maxX] + rects.flatMap { [$0.minX, $0.maxX] })
        let ys = clustered([bounds.minY, bounds.maxY] + rects.flatMap { [$0.minY, $0.maxY] })
        guard xs.count >= 2, ys.count >= 2 else { return false }

        for xIndex in 0..<(xs.count - 1) where xs[xIndex + 1] - xs[xIndex] > tolerance {
            let x = (xs[xIndex] + xs[xIndex + 1]) / 2
            for yIndex in 0..<(ys.count - 1) where ys[yIndex + 1] - ys[yIndex] > tolerance {
                let y = (ys[yIndex] + ys[yIndex + 1]) / 2
                let covering = rects.reduce(into: 0) { count, rect in
                    if x >= rect.minX - tolerance, x <= rect.maxX + tolerance,
                       y >= rect.minY - tolerance, y <= rect.maxY + tolerance {
                        count += 1
                    }
                }
                if covering != 1 { return false }
            }
        }
        return true
    }

    /// 在指定分区内增加一条分割线。
    /// coordinate 使用整个可用区域的比例坐标；落点会夹在分区两端的最小尺寸之外。
    public static func splitting(
        _ specs: [ZoneSpec],
        zoneAt index: Int,
        axis: LayoutAxis,
        coordinate: Double,
        minimumSize: Double = 0.1
    ) -> [ZoneSpec]? {
        guard specs.indices.contains(index), coordinate.isFinite,
              minimumSize.isFinite, minimumSize > 0 else { return nil }
        let zone = specs[index]
        let start = axis == .vertical ? zone.x : zone.y
        let size = axis == .vertical ? zone.w : zone.h
        guard size >= minimumSize * 2 else { return nil }

        let split = min(max(coordinate, start + minimumSize), start + size - minimumSize)
        var first = zone
        var second = zone
        switch axis {
        case .vertical:
            first.w = split - zone.x
            second.x = split
            second.w = zone.x + zone.w - split
            first.name = directionalName(zone.name, suffix: "左")
            second.name = directionalName(zone.name, suffix: "右")
        case .horizontal:
            first.h = split - zone.y
            second.y = split
            second.h = zone.y + zone.h - split
            first.name = directionalName(zone.name, suffix: "上")
            second.name = directionalName(zone.name, suffix: "下")
        }

        var result = specs
        result.replaceSubrange(index...index, with: [first, second])
        return validZones(result).count == result.count ? result : nil
    }

    /// 删除指针所在的一段分割线。
    ///
    /// T 形连接两侧跨度不一致时，先沿交叠区边界把较大的分区切开，再合并线段两侧，
    /// 因而只移除当前线段，其他分割线与整体覆盖范围保持不变。
    public static func removingDividerSegment(
        from specs: [ZoneSpec],
        axis: LayoutAxis,
        coordinate: Double,
        crossCoordinate: Double,
        tolerance: Double = 0.005
    ) -> [ZoneSpec]? {
        guard coordinate.isFinite, crossCoordinate.isFinite,
              tolerance.isFinite, tolerance >= 0 else { return nil }

        let leading = specs.indices.filter { index in
            let zone = specs[index]
            let edge = axis == .vertical ? zone.x + zone.w : zone.y + zone.h
            return abs(edge - coordinate) <= tolerance
                && crossInterval(of: zone, axis: axis)
                    .contains(crossCoordinate, tolerance: ratioEpsilon)
        }
        let trailing = specs.indices.filter { index in
            let zone = specs[index]
            let edge = axis == .vertical ? zone.x : zone.y
            return abs(edge - coordinate) <= tolerance
                && crossInterval(of: zone, axis: axis)
                    .contains(crossCoordinate, tolerance: ratioEpsilon)
        }
        // 指针正落在 T 形或十字交点时，同一侧可能同时命中两块。
        // 此时不猜用户想删哪一段；移入明确线段后候选才会各剩一个。
        guard leading.count == 1, trailing.count == 1,
              let leadingIndex = leading.first, let trailingIndex = trailing.first,
              leadingIndex != trailingIndex else { return nil }

        let first = specs[leadingIndex]
        let second = specs[trailingIndex]
        let firstEdge = axis == .vertical ? first.x + first.w : first.y + first.h
        let secondEdge = axis == .vertical ? second.x : second.y
        // 分割线聚类容许 0.5% 的视觉误差，但删除只能合并真正相邻的矩形，
        // 不能顺手填掉手写配置原本保留的细缝。
        guard abs(firstEdge - secondEdge) <= ratioEpsilon else { return nil }
        let firstCross = crossInterval(of: first, axis: axis)
        let secondCross = crossInterval(of: second, axis: axis)
        let overlapLower = max(firstCross.lowerBound, secondCross.lowerBound)
        let overlapUpper = min(firstCross.upperBound, secondCross.upperBound)
        guard overlapUpper - overlapLower > ratioEpsilon else { return nil }
        let overlap = overlapLower...overlapUpper
        guard overlap.contains(crossCoordinate, tolerance: tolerance) else { return nil }

        let merged = mergedZone(first, second, axis: axis, cross: overlap)
        let leadingRemainders = crossRemainders(of: first, removing: overlap, axis: axis)
        let trailingRemainders = crossRemainders(of: second, removing: overlap, axis: axis)

        var result: [ZoneSpec] = []
        for index in specs.indices {
            if index == leadingIndex {
                result.append(contentsOf: leadingRemainders.prefix(1))
                result.append(merged)
                result.append(contentsOf: leadingRemainders.dropFirst())
            } else if index == trailingIndex {
                result.append(contentsOf: trailingRemainders)
            } else {
                result.append(specs[index])
            }
        }
        return validZones(result).count == result.count ? result : nil
    }

    private static func directionalName(_ name: String?, suffix: String) -> String? {
        guard let name, !name.isEmpty else { return nil }
        return "\(name)·\(suffix)"
    }

    private static func crossInterval(of zone: ZoneSpec, axis: LayoutAxis) -> ClosedRange<Double> {
        axis == .vertical ? zone.y...(zone.y + zone.h) : zone.x...(zone.x + zone.w)
    }

    private static func mergedZone(
        _ leading: ZoneSpec,
        _ trailing: ZoneSpec,
        axis: LayoutAxis,
        cross: ClosedRange<Double>
    ) -> ZoneSpec {
        let name = mergedName(leading.name, trailing.name, axis: axis)
        switch axis {
        case .vertical:
            let right = trailing.x + trailing.w
            return ZoneSpec(name: name, x: leading.x, y: cross.lowerBound,
                            w: right - leading.x, h: cross.upperBound - cross.lowerBound)
        case .horizontal:
            let bottom = trailing.y + trailing.h
            return ZoneSpec(name: name, x: cross.lowerBound, y: leading.y,
                            w: cross.upperBound - cross.lowerBound, h: bottom - leading.y)
        }
    }

    private static func mergedName(_ leading: String?, _ trailing: String?, axis: LayoutAxis) -> String? {
        let suffixes = axis == .vertical ? ("·左", "·右") : ("·上", "·下")
        if let leading, let trailing,
           leading.hasSuffix(suffixes.0), trailing.hasSuffix(suffixes.1) {
            let leadingBase = String(leading.dropLast(suffixes.0.count))
            let trailingBase = String(trailing.dropLast(suffixes.1.count))
            if leadingBase == trailingBase { return leadingBase }
        }
        return leading ?? trailing
    }

    private static func crossRemainders(
        of zone: ZoneSpec,
        removing removed: ClosedRange<Double>,
        axis: LayoutAxis
    ) -> [ZoneSpec] {
        let interval = crossInterval(of: zone, axis: axis)
        var result: [ZoneSpec] = []
        if removed.lowerBound - interval.lowerBound > ratioEpsilon {
            result.append(zone.withCrossInterval(interval.lowerBound...removed.lowerBound, axis: axis))
        }
        if interval.upperBound - removed.upperBound > ratioEpsilon {
            result.append(zone.withCrossInterval(removed.upperBound...interval.upperBound, axis: axis))
        }
        return result
    }
}

private extension ZoneSpec {
    func withCrossInterval(_ interval: ClosedRange<Double>, axis: LayoutAxis) -> ZoneSpec {
        var result = self
        switch axis {
        case .vertical:
            result.y = interval.lowerBound
            result.h = interval.upperBound - interval.lowerBound
        case .horizontal:
            result.x = interval.lowerBound
            result.w = interval.upperBound - interval.lowerBound
        }
        return result
    }
}

private extension ClosedRange<Double> {
    func contains(_ value: Double, tolerance: Double) -> Bool {
        value >= lowerBound - tolerance && value <= upperBound + tolerance
    }
}
