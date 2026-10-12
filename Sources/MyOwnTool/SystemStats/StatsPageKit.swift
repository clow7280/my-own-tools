import AppKit

/// 坐标系自上而下的容器，方便页面内做“从顶部往下排”的布局
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 弹窗卡片：圆角 10 + 动态半透明底色（DESIGN.md「弹窗」）
class CardView: FlippedView {
    override func draw(_ dirtyRect: NSRect) {
        StatsPalette.cardBackground.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill()
    }
}

/// 卡片内 1pt 分隔线
final class SeparatorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        StatsPalette.separator.setFill()
        bounds.fill()
    }
}

/// 页面控件的小工厂与布局常量
enum PageUI {
    /// 弹窗内容宽（窗口 348 − 两侧 12）
    static let pageWidth: CGFloat = 324
    /// 卡片内容左右边距
    static let cardPadding: CGFloat = 12
    /// 卡片内容宽
    static let innerWidth: CGFloat = pageWidth - cardPadding * 2
    /// 卡片纵向间距
    static let cardGap: CGFloat = 10

    // 指标行三列：标签 42 | 曲线自适应 | 数值 76，列间距 8。
    // 所有卡共用同一列宽，保证 sparkline 两端和右侧指标对齐；
    // 曲线列尾部由 SparklineView 自己让出 34pt 最值刻度列。
    static let rowLabelWidth: CGFloat = 42
    static let rowValueWidth: CGFloat = 76
    static let rowGap: CGFloat = 8
    static let rowValueSize: CGFloat = 14

    static func label(_ text: String = "", size: CGFloat, weight: NSFont.Weight = .regular,
                      mono: Bool = false, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight)
                          : .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    /// 数值 + 小号单位的复合文本（如 "312 MB/s"）
    static func valueWithUnit(_ number: String, unit: String,
                              numberSize: CGFloat, unitSize: CGFloat,
                              color: NSColor = .labelColor) -> NSAttributedString {
        let text = NSMutableAttributedString(string: number, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: numberSize, weight: .semibold),
            .foregroundColor: color,
        ])
        text.append(NSAttributedString(string: " " + unit, attributes: [
            .font: NSFont.systemFont(ofSize: unitSize, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return text
    }

    static func separator(in view: NSView, y: CGFloat) {
        let line = SeparatorView()
        line.frame = NSRect(x: cardPadding, y: y, width: innerWidth, height: 1)
        view.addSubview(line)
    }
}
