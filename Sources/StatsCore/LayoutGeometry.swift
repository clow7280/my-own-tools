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
}
