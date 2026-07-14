import AppKit

/// 拖拽时覆盖在各屏幕上的分区标记层
final class OverlayManager {
    private var overlays: [(window: NSWindow, screen: NSScreen, view: OverlayView)] = []

    var isVisible: Bool { !overlays.isEmpty }

    func show() {
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
            let view = OverlayView(zoneRects: localRects)
            window.contentView = view
            window.orderFrontRegardless()
            overlays.append((window, screen, view))
        }
    }

    func hide() {
        overlays.forEach { $0.window.orderOut(nil) }
        overlays.removeAll()
    }

    func highlight(screen: NSScreen?, zoneIndex: Int?) {
        for overlay in overlays {
            overlay.view.hoveredIndex = (overlay.screen == screen) ? zoneIndex : nil
        }
    }
}

/// 绘制浅色半透明的分区标记
final class OverlayView: NSView {
    private let zoneRects: [CGRect]

    var hoveredIndex: Int? {
        didSet { if hoveredIndex != oldValue { needsDisplay = true } }
    }

    init(zoneRects: [CGRect]) {
        self.zoneRects = zoneRects
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for (index, zone) in zoneRects.enumerated() {
            let rect = zone.insetBy(dx: 6, dy: 6)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            let hovered = index == hoveredIndex
            accent.withAlphaComponent(hovered ? 0.32 : 0.10).setFill()
            path.fill()
            accent.withAlphaComponent(hovered ? 0.90 : 0.35).setStroke()
            path.lineWidth = hovered ? 2 : 1
            path.stroke()
        }
    }
}
