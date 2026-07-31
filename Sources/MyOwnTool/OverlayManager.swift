import AppKit
import StatsCore

enum SnapTargetKind: Equatable {
    case zone(Int)
    case fullScreen
    case focus
}

struct SnapTarget {
    let screen: NSScreen
    let kind: SnapTargetKind
    let rect: CGRect
}

/// 拖拽时覆盖在各屏幕上的分区标记层
final class OverlayManager {
    private var overlays: [(window: NSWindow, screen: NSScreen, view: OverlayView)] = []

    var isVisible: Bool { !overlays.isEmpty }

    func show(focusSize: CGSize) {
        guard overlays.isEmpty else { return }
        for screen in NSScreen.screens {
            let rects = LayoutProvider.zoneRects(for: screen)
            guard !rects.isEmpty else { continue }

            let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

            let localRects = rects.map { $0.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY) }
            let special = Self.specialTargetRects(in: screen.visibleFrame)
            let focusRect = LayoutGeometry.focusRect(windowSize: focusSize, in: screen.visibleFrame)
            let view = OverlayView(
                zoneRects: localRects,
                fullScreenRect: screen.visibleFrame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                focusRect: focusRect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                fullScreenTargetRect: special.fullScreen.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY),
                focusTargetRect: special.focus.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY))
            window.contentView = view
            window.orderFrontRegardless()
            overlays.append((window, screen, view))
        }
    }

    func hide() {
        overlays.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()
    }

    func target(at point: CGPoint) -> SnapTarget? {
        guard let overlay = overlays.first(where: { NSMouseInRect(point, $0.screen.frame, false) }) else {
            return nil
        }
        let screen = overlay.screen
        let special = Self.specialTargetRects(in: screen.visibleFrame)
        if special.fullScreen.contains(point) {
            return SnapTarget(screen: screen, kind: .fullScreen, rect: screen.visibleFrame)
        }
        if special.focus.contains(point) {
            return SnapTarget(
                screen: screen,
                kind: .focus,
                rect: LayoutGeometry.focusRect(windowSize: overlay.view.focusSize, in: screen.visibleFrame))
        }
        let rects = LayoutProvider.zoneRects(for: screen)
        guard let index = rects.firstIndex(where: { $0.contains(point) }) else { return nil }
        return SnapTarget(screen: screen, kind: .zone(index), rect: rects[index])
    }

    func highlight(_ target: SnapTarget?) {
        for overlay in overlays {
            overlay.view.highlightedTarget = overlay.screen == target?.screen ? target?.kind : nil
        }
    }

    private static func specialTargetRects(in area: CGRect) -> (fullScreen: CGRect, focus: CGRect) {
        let size = CGSize(width: 78, height: 28)
        let gap: CGFloat = 8
        let totalWidth = size.width * 2 + gap
        let y = area.maxY - 12 - size.height
        let left = area.midX - totalWidth / 2
        return (
            CGRect(x: left, y: y, width: size.width, height: size.height),
            CGRect(x: left + size.width + gap, y: y, width: size.width, height: size.height)
        )
    }
}

/// 绘制浅色半透明的分区标记
final class OverlayView: NSView {
    private let zoneRects: [CGRect]
    private let fullScreenRect: CGRect
    private let focusRect: CGRect
    private let fullScreenTargetRect: CGRect
    private let focusTargetRect: CGRect

    var focusSize: CGSize { focusRect.size }

    var highlightedTarget: SnapTargetKind? {
        didSet { if highlightedTarget != oldValue { needsDisplay = true } }
    }

    init(
        zoneRects: [CGRect],
        fullScreenRect: CGRect,
        focusRect: CGRect,
        fullScreenTargetRect: CGRect,
        focusTargetRect: CGRect
    ) {
        self.zoneRects = zoneRects
        self.fullScreenRect = fullScreenRect
        self.focusRect = focusRect
        self.fullScreenTargetRect = fullScreenTargetRect
        self.focusTargetRect = focusTargetRect
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for (index, zone) in zoneRects.enumerated() {
            let rect = zone.insetBy(dx: 6, dy: 6)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            let hovered = highlightedTarget == .zone(index)
            accent.withAlphaComponent(hovered ? 0.32 : 0.10).setFill()
            path.fill()
            accent.withAlphaComponent(hovered ? 0.90 : 0.35).setStroke()
            path.lineWidth = hovered ? 2 : 1
            path.stroke()
        }

        switch highlightedTarget {
        case .fullScreen:
            drawPreview(fullScreenRect, accent: accent)
        case .focus:
            drawPreview(focusRect, accent: accent)
        default:
            break
        }
        drawSpecialTarget(fullScreenTargetRect, title: "全屏", active: highlightedTarget == .fullScreen)
        drawSpecialTarget(focusTargetRect, title: "专注", active: highlightedTarget == .focus)
    }

    private func drawPreview(_ rect: CGRect, accent: NSColor) {
        let preview = rect.insetBy(dx: 6, dy: 6)
        let path = NSBezierPath(roundedRect: preview, xRadius: 12, yRadius: 12)
        accent.withAlphaComponent(0.32).setFill()
        path.fill()
        accent.withAlphaComponent(0.90).setStroke()
        path.lineWidth = 2
        path.stroke()
    }

    private func drawSpecialTarget(_ rect: CGRect, title: String, active: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        (active ? NSColor.controlAccentColor : NSColor.black.withAlphaComponent(0.55)).setFill()
        path.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = title.size(withAttributes: attributes)
        title.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                   withAttributes: attributes)
    }
}
