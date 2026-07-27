import Foundation

/// 温度分级（离散状态色）：菜单栏竖柱边框与弹窗温度数值。
/// CPU/GPU 柱取自身温度，RAM 柱取硬盘温度；≥90℃ 为紧急档，边框闪烁。
///
/// 档位阈值属于纯逻辑放在这里，对应的 NSColor 由 MyOwnTool 侧的扩展提供，见 DESIGN.md。
public enum TempTier {
    case cool       // < 45℃
    case warm       // 45–60℃
    case hot        // 60–75℃
    case searing    // 75–90℃
    case critical   // ≥ 90℃

    public init?(_ temp: Double?) {
        guard let temp else { return nil }
        switch temp {
        case ..<45: self = .cool
        case ..<60: self = .warm
        case ..<75: self = .hot
        case ..<90: self = .searing
        default: self = .critical
        }
    }
}
