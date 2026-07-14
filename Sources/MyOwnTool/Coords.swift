import AppKit

/// Cocoa（左下原点）与 Accessibility（左上原点）全局坐标互转
enum Coords {
    private static var primaryFrame: CGRect {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame
            ?? NSScreen.screens.first?.frame
            ?? .zero
    }

    static func cocoaToAX(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryFrame.maxY - point.y)
    }

    static func cocoaToAX(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryFrame.maxY - rect.maxY, width: rect.width, height: rect.height)
    }
}
