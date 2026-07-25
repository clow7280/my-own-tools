import AppKit

/// 固定调色板——DESIGN.md 的代码对应物，改动前先改文档。
/// 每个指标色有标准/弱化/深色态变体（NSColor 动态解析浅深外观）。
/// 美观优先：所有者非色盲，色盲分离不作为门槛，见 DESIGN.md「设计原则」。
enum StatsPalette {
    // 指标色（标准）：菜单栏竖柱填充、占用 sparkline、环外圈
    static let cpu = dynamic(0x3478F6, 1, 0x5C97FF, 1)          // 蓝
    static let gpu = dynamic(0x9A5CD0, 1, 0xB57BE8, 1)          // 紫
    static let ram = dynamic(0x00A2C7, 1, 0x2BC2E4, 1)          // 青

    // 指标色（弱化）：温度 sparkline 均值线
    static let cpuSoft = dynamic(0x3478F6, 0.55, 0x5C97FF, 0.6)
    static let gpuSoft = dynamic(0x9A5CD0, 0.55, 0xB57BE8, 0.6)

    // 指标色（更弱）：温度 sparkline 上叠加的峰值线，压在均值线之下不抢视线
    static let cpuFaint = dynamic(0x3478F6, 0.3, 0x5C97FF, 0.35)
    static let gpuFaint = dynamic(0x9A5CD0, 0.3, 0xB57BE8, 0.35)

    // AI 品牌强调色：同一提供方的全部订阅周期统一使用标准色；深变体只给专属模型与徽章
    static let chatGPT = dynamic(0x10A37F, 1, 0x1FBF93, 1)      // OpenAI 青绿
    static let chatGPTDeep = dynamic(0x10A37F, 1, 0x1FBF93, 1)
    static let claude = dynamic(0xD97757, 1, 0xE8906B, 1)       // Claude 珊瑚
    static let claudeDeep = dynamic(0xC05A38, 1, 0xD97757, 1)
    static let openCode = dynamic(0x111111, 1, 0xF2F2F2, 1)     // OpenCode 动态墨色
    static let openCodeDeep = openCode

    // 徽章底色（品牌色低透明度）
    static let chatGPTBadgeBG = dynamic(0x10A37F, 0.13, 0x1FBF93, 0.2)
    static let claudeBadgeBG = dynamic(0xD97757, 0.15, 0xE8906B, 0.22)
    static let openCodeBadgeBG = dynamic(0x111111, 0.1, 0xF2F2F2, 0.16)

    // 轨道中性色
    static let barTrack = dynamic(0x000000, 0.09, 0xFFFFFF, 0.18)     // 菜单栏竖柱
    static let ringTrack = dynamic(0x000000, 0.18, 0xFFFFFF, 0.3)     // 菜单栏双层环（加深保形状可读）
    static let usageTrack = dynamic(0x000000, 0.1, 0xFFFFFF, 0.16)    // 弹窗用量条

    // 磁盘/网络 sparkline 的中性双线（主 = 下载/读取，副 = 上传/写入）
    static let neutralPrimary = dynamic(0x000000, 0.6, 0xFFFFFF, 0.65)
    static let neutralSecondary = dynamic(0x000000, 0.32, 0xFFFFFF, 0.35)

    // 时长切换胶囊底色（常态 / 悬停）
    static let capsuleBackground = dynamic(0x000000, 0.05, 0xFFFFFF, 0.08)
    static let capsuleHoverBackground = dynamic(0x000000, 0.09, 0xFFFFFF, 0.13)

    // 弹窗卡片
    static let cardBackground = dynamic(0xFFFFFF, 0.6, 0xFFFFFF, 0.07)
    static let separator = dynamic(0x000000, 0.06, 0xFFFFFF, 0.08)

    /// 浅/深外观各自的十六进制色 + 透明度；alpha 在动态提供闭包内应用，
    /// 避免 withAlphaComponent 提前解析掉动态性
    static func dynamic(_ light: Int, _ lightAlpha: CGFloat, _ dark: Int, _ darkAlpha: CGFloat) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        }
    }

    private static func rgb(_ hex: Int, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

/// 温度分级（离散状态色）：菜单栏竖柱边框与弹窗温度数值。
/// CPU/GPU 柱取自身温度，RAM 柱取硬盘温度；≥90℃ 为紧急档，边框闪烁。
enum TempTier {
    case cool       // < 45℃
    case warm       // 45–60℃
    case hot        // 60–75℃
    case searing    // 75–90℃
    case critical   // ≥ 90℃

    init?(_ temp: Double?) {
        guard let temp else { return nil }
        switch temp {
        case ..<45: self = .cool
        case ..<60: self = .warm
        case ..<75: self = .hot
        case ..<90: self = .searing
        default: self = .critical
        }
    }

    /// 竖柱边框色
    var border: NSColor {
        switch self {
        case .cool: return StatsPalette.dynamic(0x787880, 0.38, 0xFFFFFF, 0.35)
        case .warm: return StatsPalette.dynamic(0xE7C100, 1, 0xE7C100, 1)
        case .hot: return StatsPalette.dynamic(0xFF9F0A, 1, 0xFF9F0A, 1)
        case .searing: return StatsPalette.dynamic(0xFF5A1F, 1, 0xFF5A1F, 1)
        case .critical: return StatsPalette.dynamic(0xFF2D55, 1, 0xFF2D55, 1)
        }
    }

    /// 弹窗温度数值文字色；常温返回 nil 表示用默认标签色
    var text: NSColor? {
        switch self {
        case .cool: return nil
        case .warm: return StatsPalette.dynamic(0xC29B00, 1, 0xF0D24A, 1)
        case .hot: return StatsPalette.dynamic(0xE08900, 1, 0xFFB340, 1)
        case .searing, .critical: return border
        }
    }
}
