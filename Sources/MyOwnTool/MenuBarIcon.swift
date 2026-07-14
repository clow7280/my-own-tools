import AppKit

/// 菜单栏图标：简约线条版双咖啡豆（模板图，自动适配菜单栏明暗）
enum MenuBarIcon {
    private static let designSize = NSSize(width: 20, height: 16)

    static func make() -> NSImage {
        let image = NSImage(size: designSize, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.scaleBy(x: rect.width / designSize.width, y: rect.height / designSize.height)
            // 左小右大，底部大致对齐
            drawBean(ctx, center: CGPoint(x: 5.3, y: 6.6), width: 5.6, height: 10.5, angle: .pi * 12 / 180)
            drawBean(ctx, center: CGPoint(x: 13.8, y: 8), width: 7.4, height: 14, angle: -.pi * 12 / 180)
            ctx.restoreGState()
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawBean(_ ctx: CGContext, center: CGPoint, width w: CGFloat, height h: CGFloat, angle: CGFloat) {
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.rotate(by: angle)
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
        ctx.setLineCap(.round)

        // 豆体轮廓
        ctx.setLineWidth(1.4)
        ctx.strokeEllipse(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))

        // 中缝 S 曲线
        let inset = h * 0.18
        let crease = CGMutablePath()
        crease.move(to: CGPoint(x: 0, y: -h / 2 + inset))
        crease.addCurve(to: CGPoint(x: 0, y: 0),
                        control1: CGPoint(x: w * 0.26, y: -h * 0.30),
                        control2: CGPoint(x: w * 0.26, y: -h * 0.07))
        crease.addCurve(to: CGPoint(x: 0, y: h / 2 - inset),
                        control1: CGPoint(x: -w * 0.26, y: h * 0.07),
                        control2: CGPoint(x: -w * 0.26, y: h * 0.30))
        ctx.addPath(crease)
        ctx.setLineWidth(1.2)
        ctx.strokePath()

        ctx.restoreGState()
    }
}
