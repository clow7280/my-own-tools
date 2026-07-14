import AppKit

/// 固定调色板——DESIGN.md 的代码对应物，改动前先改文档。
/// 浅/深色成对定义（NSColor 动态解析）。美观优先：蓝→紫→粉邻近色相组（所有者非色盲，
/// 色盲分离不作为门槛，见 DESIGN.md「设计原则」）。
enum StatsPalette {
    // 指标色（菜单栏竖条填充 + 弹窗曲线）
    static let cpu = dynamic(light: 0x3B82F6, dark: 0x60A5FA)      // 蓝
    static let gpu = dynamic(light: 0x8B5CF6, dark: 0xA78BFA)      // 紫
    // 粉色感知亮度天然高于蓝/紫，取深一档（600/500）平衡三条的视觉强度
    static let ram = dynamic(light: 0xDB2777, dark: 0xEC4899)      // 粉

    // AI 品牌色（预留给订阅用量横条）
    static let openAI = dynamic(light: 0x10A37F, dark: 0x10A37F)   // OpenAI 青绿
    static let claude = dynamic(light: 0xD97757, dark: 0xCC6B4A)   // Claude 珊瑚

    // 网络图（沿用 红=上传 蓝=下载 惯例，蓝与 CPU 同色但不同页面出现）
    static let netUp = dynamic(light: 0xE34948, dark: 0xE66767)
    static let netDown = dynamic(light: 0x3B82F6, dark: 0x60A5FA)

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1)
    }
}
