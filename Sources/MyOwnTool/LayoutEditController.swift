import AppKit
import StatsCore

/// 长按 Shift 1.2 秒（期间无按键与鼠标操作）进入分割线编辑模式：
/// 每条分割线上覆盖一个本应用的细条手柄窗口，拖动手柄即按比例调整两侧分区；
/// 右键分区可增加横向或纵向分割，右键分割线删除指针所在的线段；
/// 松开 Shift 保存到布局配置，按 Esc 放弃本次修改。
///
/// 拖拽交互全部发生在自己的手柄窗口内，不经过全局监听；
/// 全局监视器仍保持只读，不改变系统事件投递。
///
/// 两个 Shift 手势的优先级（拖窗手势在 SnapController）：
/// 1. 鼠标一旦参与就归 SnapController：任何鼠标按下、拖动或滚轮都会取消长按计时，
///    所以 Shift 拖窗口期间不会顺带进编辑模式；
///    计时器到点时还会复查「只按住 Shift 且无鼠标键」，挡住计时窗口内漏掉的边界情况。
/// 2. 长按满 1.2 秒进入编辑模式后编辑优先，本控制器通过 onEditingChanged 挂起 SnapController，
///    此时的 Shift 拖拽不再吸附窗口，退出编辑模式后自动恢复。
/// 3. 计时只在 flagsChanged 报告「修饰键恰好只剩 Shift」时重新开始，
///    因此一次 Shift 拖拽结束后即便手指还按着 Shift 也不会补进编辑模式，
///    必须松开再按一次，避免拖完窗口手一慢就被覆盖层糊一脸。
final class LayoutEditController {
    private var eventMonitor: Any?
    private var localMonitor: Any?
    private var longPressTimer: Timer?
    private var sessions: [ScreenEditSession] = []

    /// 进入 / 退出编辑模式的通知，用于让 SnapController 让位
    var onEditingChanged: ((Bool) -> Void)?

    /// 与 SnapController.isEnabled 同源：设置页的「拖拽分屏」开关同时管这两个 Shift 手势，
    /// 用户关掉分屏后不该还有 Shift 手势拦截。持久化由 SnapController 负责，这里只跟随，
    /// 免得两处各写一份 UserDefaults 又要担心谁先谁后。
    var isEnabled = true {
        didSet {
            if !isEnabled {
                cancelTimer()
                // 关开关不是「编辑完成」，未提交的改动直接丢弃，不写回配置
                exitEditMode(commit: false)
            }
        }
    }

    private var isEditing: Bool { !sessions.isEmpty }

    func start() {
        guard eventMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .flagsChanged, .keyDown,
            .leftMouseDown, .rightMouseDown, .otherMouseDown,
            .leftMouseDragged, .scrollWheel,
        ]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
        // 全局监视器收不到投递给本应用的事件；当本应用处于激活状态时
        // （如弹窗获得焦点），由本地监视器兜底捕获 Shift 释放与 Esc
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    /// 应用退出前撤掉定时器、事件监视器与覆盖窗口
    func stop() {
        cancelTimer()
        // 退出应用不是用户确认编辑的动作，未提交的改动一律丢弃
        exitEditMode(commit: false)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled else { return }
        switch event.type {
        case .flagsChanged:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .shift {
                // 只在没有鼠标键按下时起算，Shift 拖窗口途中的修饰键抖动不该开始计时
                if !isEditing, NSEvent.pressedMouseButtons == 0 { startTimer() }
            } else {
                cancelTimer()
                if isEditing, !flags.contains(.shift) { exitEditMode(commit: true) }
            }
        case .keyDown:
            // 长按期间出现任何按键（含 Shift 组合键）说明用户在正常输入，取消进入
            cancelTimer()
            if isEditing, event.keyCode == 53 { exitEditMode(commit: false) }    // Esc 放弃
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            cancelTimer()
            // 手柄窗口上的点击不会出现在全局监视器里；
            // 出现在这里的点击都发生在别处，视为开始其他操作（如拖窗吸附），保存并退出
            if isEditing { exitEditMode(commit: true) }
        default:
            cancelTimer()
        }
    }

    private func startTimer() {
        cancelTimer()
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 1.2, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.longPressTimer = nil
            // 触发时再确认仍是「只按住 Shift 且无鼠标按键」
            guard NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask) == .shift,
                  NSEvent.pressedMouseButtons == 0 else { return }
            self.enterEditMode()
        }
    }

    private func cancelTimer() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    private func enterEditMode() {
        guard !isEditing else { return }
        for screen in NSScreen.screens {
            let specs = LayoutProvider.specs(for: screen)
            guard !specs.isEmpty else { continue }
            sessions.append(ScreenEditSession(screen: screen, specs: specs))
        }
        guard isEditing else { return }     // 一个分区都没有时不算进入，也就不必挂起吸附
        onEditingChanged?(true)
    }

    private func exitEditMode(commit: Bool) {
        guard isEditing else { return }
        let ended = sessions
        sessions = []
        onEditingChanged?(false)
        for session in ended {
            session.teardown()
            guard commit else { continue }
            // 只有用户真的把分割线拖动过才写回；两侧都取归一化形态再比，
            // 免得手写配置里 0.66666666 这类值仅仅因为进出编辑模式就被重写
            let edited = session.specs.map { $0.normalizedForStorage() }
            guard edited != session.originalSpecs.map({ $0.normalizedForStorage() }) else { continue }
            LayoutStore.save(specs: edited, for: session.screen)
        }
    }
}

/// 分区之间的一条分割线：同一坐标上重合的分区边聚合而成，整线联动拖拽
struct LayoutDivider {
    let axis: LayoutAxis
    /// 分割线在拖动轴上的比例坐标（0~1）
    var coordinate: Double
    /// 分割线沿自身方向的覆盖区间（另一轴的比例值）
    let span: ClosedRange<Double>
    /// 以该线为右/下边的分区索引
    let leading: [Int]
    /// 以该线为左/上边的分区索引
    let trailing: [Int]
    /// 允许拖动的坐标范围，保证两侧分区不小于最小尺寸
    let range: ClosedRange<Double>
}

/// 单个屏幕的编辑会话：一个可接收右键的展示层窗口 + 每条分割线一个可交互手柄窗口
final class ScreenEditSession {
    /// 边坐标聚类阈值（比例值）
    private static let epsilon = 0.005
    /// 分区在拖动轴上的最小尺寸（比例值）
    private static let minZoneSize = 0.1
    /// 磁吸网格：对半与三分位置；命中阈值为屏幕尺寸的 1.5%
    private static let snapTargets = [1.0 / 3, 0.5, 2.0 / 3]
    private static let snapThreshold = 0.015
    /// 手柄条厚度，以及展示层里线条的常态与高亮厚度
    private static let handleThickness: CGFloat = 10
    private static let lineThickness: CGFloat = 4
    private static let activeLineThickness: CGFloat = 8
    /// 手柄窗口层级：盖在展示层之上
    private static let handleLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    let screen: NSScreen
    let originalSpecs: [ZoneSpec]
    private(set) var specs: [ZoneSpec]

    /// teardown 后置 false：拖拽途中退出编辑时，晚到的拖拽回调不得重建窗口
    private var isActive = true
    private var dividers: [LayoutDivider] = []
    private var hoveredIndex: Int?
    private var draggingIndex: Int?
    private var overlayWindow: NSWindow?
    private var overlayView: EditOverlayView?
    private var handleWindows: [NSWindow] = []

    init(screen: NSScreen, specs: [ZoneSpec]) {
        self.screen = screen
        self.specs = specs
        self.originalSpecs = specs
        buildOverlay()
        rebuildDividers()
    }

    func teardown() {
        isActive = false
        handleWindows.forEach { $0.orderOut(nil) }
        handleWindows = []
        overlayWindow?.orderOut(nil)
        overlayWindow = nil
        overlayView = nil
        // 手柄窗口撤走后不再有人更新光标，缩放箭头会一直挂到下次移进别的窗口为止
        NSCursor.arrow.set()
    }

    // MARK: - 几何换算

    /// 分区基于可用区域，自动避开菜单栏与 Dock；与 LayoutProvider.zoneRects 同一套算法
    private var area: CGRect { screen.visibleFrame }

    /// Cocoa 全局坐标 → 本屏窗口局部坐标
    private func localRect(_ global: CGRect) -> CGRect {
        global.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    }

    private func zoneRect(_ spec: ZoneSpec) -> CGRect {
        CGRect(x: area.minX + area.width * spec.x,
               y: area.minY + area.height * (1 - spec.y - spec.h),
               width: area.width * spec.w,
               height: area.height * spec.h)
    }

    /// 分割线在 Cocoa 全局坐标下的条状矩形
    private func dividerFrame(_ divider: LayoutDivider, thickness: CGFloat) -> CGRect {
        switch divider.axis {
        case .vertical:
            let x = area.minX + area.width * divider.coordinate
            let yMin = area.maxY - area.height * divider.span.upperBound
            let height = area.height * (divider.span.upperBound - divider.span.lowerBound)
            return CGRect(x: x - thickness / 2, y: yMin, width: thickness, height: height)
        case .horizontal:
            let y = area.maxY - area.height * divider.coordinate
            let xMin = area.minX + area.width * divider.span.lowerBound
            let width = area.width * (divider.span.upperBound - divider.span.lowerBound)
            return CGRect(x: xMin, y: y - thickness / 2, width: width, height: thickness)
        }
    }

    // MARK: - 分割线计算

    /// 把同轴上坐标重合（epsilon 内）的分区边聚成分割线；
    /// 同坐标的多段边一起移动，保持整线对齐（默认外接布局的竖线会带动 4 个分区）
    private static func computeDividers(specs: [ZoneSpec]) -> [LayoutDivider] {
        var result: [LayoutDivider] = []
        for axis in [LayoutAxis.vertical, .horizontal] {
            var edges: [(c: Double, index: Int, leading: Bool)] = []
            for (index, spec) in specs.enumerated() {
                let start = axis == .vertical ? spec.x : spec.y
                let size = axis == .vertical ? spec.w : spec.h
                if start > epsilon { edges.append((start, index, false)) }
                if start + size < 1 - epsilon { edges.append((start + size, index, true)) }
            }
            edges.sort { $0.c < $1.c }

            var cluster: [(c: Double, index: Int, leading: Bool)] = []
            func flush() {
                defer { cluster = [] }
                guard !cluster.isEmpty else { return }
                let coordinate = cluster.map(\.c).reduce(0, +) / Double(cluster.count)
                let leading = cluster.filter(\.leading).map(\.index)
                let trailing = cluster.filter { !$0.leading }.map(\.index)
                var lower = epsilon, upper = 1 - epsilon
                for i in leading {
                    lower = max(lower, (axis == .vertical ? specs[i].x : specs[i].y) + minZoneSize)
                }
                for i in trailing {
                    let end = axis == .vertical ? specs[i].x + specs[i].w : specs[i].y + specs[i].h
                    upper = min(upper, end - minZoneSize)
                }
                guard lower <= upper else { return }    // 没有可动空间的线不给手柄
                var spanLow = 1.0, spanHigh = 0.0
                for edge in cluster {
                    let spec = specs[edge.index]
                    let crossStart = axis == .vertical ? spec.y : spec.x
                    let crossSize = axis == .vertical ? spec.h : spec.w
                    spanLow = min(spanLow, crossStart)
                    spanHigh = max(spanHigh, crossStart + crossSize)
                }
                result.append(LayoutDivider(axis: axis, coordinate: coordinate,
                                            span: spanLow...spanHigh,
                                            leading: leading, trailing: trailing,
                                            range: lower...upper))
            }
            for edge in edges {
                if let first = cluster.first, edge.c - first.c > epsilon { flush() }
                cluster.append(edge)
            }
            flush()
        }
        return result
    }

    // MARK: - 窗口装配

    private func buildOverlay() {
        let window = makeWindow(frame: screen.frame, interactive: true, level: .screenSaver)
        let view = EditOverlayView(visibleLocal: localRect(area))
        view.onSplit = { [weak self] index, axis, mouse in
            self?.split(zoneAt: index, axis: axis, mouse: mouse)
        }
        window.contentView = view
        window.orderFrontRegardless()
        overlayWindow = window
        overlayView = view
    }

    private func rebuildDividers() {
        guard isActive else { return }
        dividers = Self.computeDividers(specs: specs)
        draggingIndex = nil
        rebuildHandles()
        // 重建后跟踪区的进入事件不会立即补发，用当前鼠标位置恢复悬停状态
        hoveredIndex = dividers.firstIndex {
            dividerFrame($0, thickness: Self.handleThickness).contains(NSEvent.mouseLocation)
        }
        refreshOverlay()
    }

    private func rebuildHandles() {
        handleWindows.forEach { $0.orderOut(nil) }
        handleWindows = []
        for (index, divider) in dividers.enumerated() {
            let window = makeWindow(frame: dividerFrame(divider, thickness: Self.handleThickness),
                                    interactive: true)
            let view = DividerHandleView(axis: divider.axis)
            view.onHover = { [weak self] hovering in self?.setHover(dividerAt: index, hovering: hovering) }
            view.onDrag = { [weak self] mouse in self?.drag(dividerAt: index, to: mouse) }
            view.onDragEnd = { [weak self] in
                // 拖拽结束后重聚类并重建手柄；延迟到事件处理结束，避免在回调中销毁事件来源窗口
                DispatchQueue.main.async { self?.rebuildDividers() }
            }
            view.onDelete = { [weak self] mouse in self?.removeDividerSegment(at: index, mouse: mouse) }
            window.contentView = view
            window.orderFrontRegardless()
            handleWindows.append(window)
        }
    }

    private func setHover(dividerAt index: Int, hovering: Bool) {
        guard isActive else { return }
        if hovering {
            hoveredIndex = index
        } else if hoveredIndex == index {
            hoveredIndex = nil
        }
        refreshOverlay()
    }

    private func makeWindow(
        frame: CGRect,
        interactive: Bool,
        level: NSWindow.Level? = nil
    ) -> NSWindow {
        // 手柄用非激活面板：点击不能激活本应用，否则后续 Shift 释放的
        // flagsChanged 会投递给自身，只读全局监视器就收不到、无法退出编辑
        let window: NSWindow = interactive
            ? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                      backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = level ?? (interactive ? Self.handleLevel : .screenSaver)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = !interactive
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return window
    }

    // MARK: - 拖拽

    private func split(zoneAt index: Int, axis: LayoutAxis, mouse: CGPoint) {
        guard isActive else { return }
        let coordinate = axis == .vertical
            ? (mouse.x - area.minX) / area.width
            : (area.maxY - mouse.y) / area.height
        guard let updated = LayoutGeometry.splitting(
            specs, zoneAt: index, axis: axis, coordinate: coordinate,
            minimumSize: Self.minZoneSize) else { return }
        specs = updated
        rebuildDividers()
    }

    private func removeDividerSegment(at index: Int, mouse: CGPoint) {
        guard isActive, dividers.indices.contains(index) else { return }
        let divider = dividers[index]
        let crossCoordinate = divider.axis == .vertical
            ? (area.maxY - mouse.y) / area.height
            : (mouse.x - area.minX) / area.width
        guard let updated = LayoutGeometry.removingDividerSegment(
            from: specs,
            axis: divider.axis,
            coordinate: divider.coordinate,
            crossCoordinate: crossCoordinate,
            tolerance: Self.epsilon) else { return }
        specs = updated
        rebuildDividers()
    }

    private func drag(dividerAt index: Int, to mouse: CGPoint) {
        guard isActive, dividers.indices.contains(index) else { return }
        var divider = dividers[index]
        let raw: Double
        switch divider.axis {
        case .vertical: raw = (mouse.x - area.minX) / area.width
        case .horizontal: raw = (area.maxY - mouse.y) / area.height
        }
        var coordinate = min(max(raw, divider.range.lowerBound), divider.range.upperBound)
        // 磁吸：靠近网格线且网格线在可动范围内时吸附过去
        if let target = Self.snapTargets
            .filter({ divider.range.contains($0) })
            .min(by: { abs($0 - coordinate) < abs($1 - coordinate) }),
            abs(target - coordinate) < Self.snapThreshold {
            coordinate = target
        }
        divider.coordinate = coordinate
        dividers[index] = divider

        for i in divider.leading {
            if divider.axis == .vertical { specs[i].w = coordinate - specs[i].x }
            else { specs[i].h = coordinate - specs[i].y }
        }
        for i in divider.trailing {
            if divider.axis == .vertical {
                let end = specs[i].x + specs[i].w
                specs[i].x = coordinate
                specs[i].w = end - coordinate
            } else {
                let end = specs[i].y + specs[i].h
                specs[i].y = coordinate
                specs[i].h = end - coordinate
            }
        }

        if handleWindows.indices.contains(index) {
            handleWindows[index].setFrame(dividerFrame(divider, thickness: Self.handleThickness),
                                          display: false)
        }
        draggingIndex = index
        refreshOverlay()
    }

    private func refreshOverlay() {
        // 悬停或拖拽中的分割线加粗提亮，提示「可拖动」
        let highlight = draggingIndex ?? hoveredIndex
        overlayView?.update(zoneRects: specs.map { localRect(zoneRect($0)) },
                            dividerRects: dividers.enumerated().map { index, divider in
                                let thickness = index == highlight
                                    ? Self.activeLineThickness
                                    : Self.lineThickness
                                return localRect(dividerFrame(divider, thickness: thickness))
                            },
                            activeIndex: highlight)
    }
}

/// 手柄窗口的内容视图：捕获拖拽并显示缩放光标；本身不绘制，线条由展示层绘制
final class DividerHandleView: NSView {
    private let axis: LayoutAxis
    var onHover: ((Bool) -> Void)?
    var onDrag: ((CGPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    var onDelete: ((CGPoint) -> Void)?

    init(axis: LayoutAxis) {
        self.axis = axis
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 手柄窗口从不成为 key window，cursor rects 不生效，用 activeAlways 的跟踪区设置光标
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.cursorUpdate, .mouseEnteredAndExited,
                                                 .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) {
        (axis == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).set()
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        onDragEnd?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onDelete?(NSEvent.mouseLocation)
    }
}

/// 编辑模式的展示层：绘制分区轮廓、分割线与操作提示
final class EditOverlayView: NSView {
    private let visibleLocal: CGRect
    private var zoneRects: [CGRect] = []
    private var dividerRects: [CGRect] = []
    private var activeIndex: Int?
    private var pendingSplit: (zoneIndex: Int, mouse: CGPoint)?
    var onSplit: ((Int, LayoutAxis, CGPoint) -> Void)?

    init(visibleLocal: CGRect) {
        self.visibleLocal = visibleLocal
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    func update(zoneRects: [CGRect], dividerRects: [CGRect], activeIndex: Int?) {
        self.zoneRects = zoneRects
        self.dividerRects = dividerRects
        self.activeIndex = activeIndex
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for zone in zoneRects {
            let rect = zone.insetBy(dx: 6, dy: 6)
            let path = NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12)
            accent.withAlphaComponent(0.08).setFill()
            path.fill()
            accent.withAlphaComponent(0.35).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        for (index, rect) in dividerRects.enumerated() {
            let radius = min(rect.width, rect.height) / 2
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            accent.withAlphaComponent(index == activeIndex ? 1.0 : 0.6).setFill()
            path.fill()
        }
        for zone in zoneRects { drawZoneSize(zone) }
        drawHint()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = zoneRects.firstIndex(where: { $0.contains(point) }) else { return }
        pendingSplit = (index, NSEvent.mouseLocation)

        let menu = NSMenu()
        let vertical = NSMenuItem(title: "左右分割", action: #selector(splitVertically), keyEquivalent: "")
        vertical.target = self
        menu.addItem(vertical)
        let horizontal = NSMenuItem(title: "上下分割", action: #selector(splitHorizontally), keyEquivalent: "")
        horizontal.target = self
        menu.addItem(horizontal)
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    @objc private func splitVertically() {
        performSplit(axis: .vertical)
    }

    @objc private func splitHorizontally() {
        performSplit(axis: .horizontal)
    }

    private func performSplit(axis: LayoutAxis) {
        guard let pendingSplit else { return }
        self.pendingSplit = nil
        onSplit?(pendingSplit.zoneIndex, axis, pendingSplit.mouse)
    }

    private func drawZoneSize(_ zone: CGRect) {
        let width = Int(zone.width.rounded())
        let height = Int(zone.height.rounded())
        let text = "\(width) × \(height) pt"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 8, height: 4)
        let badge = CGRect(
            x: zone.midX - textSize.width / 2 - padding.width,
            y: zone.midY - textSize.height / 2 - padding.height,
            width: textSize.width + padding.width * 2,
            height: textSize.height + padding.height * 2)
        let path = NSBezierPath(roundedRect: badge, xRadius: 6, yRadius: 6)
        NSColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
        text.draw(
            at: CGPoint(x: badge.minX + padding.width, y: badge.minY + padding.height),
            withAttributes: attributes)
    }

    private func drawHint() {
        let text = "拖动调整 · 右键分区新增 · 右键分割线删除 · 松开 Shift 保存 · Esc 放弃"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let textSize = text.size(withAttributes: attributes)
        let padding = CGSize(width: 16, height: 8)
        let badgeSize = CGSize(width: textSize.width + padding.width * 2,
                               height: textSize.height + padding.height * 2)
        let badge = CGRect(x: visibleLocal.midX - badgeSize.width / 2,
                           y: visibleLocal.maxY - 48 - badgeSize.height,
                           width: badgeSize.width, height: badgeSize.height)
        let path = NSBezierPath(roundedRect: badge, xRadius: badgeSize.height / 2,
                                yRadius: badgeSize.height / 2)
        // 提示条固定深底白字：覆盖层压在任意应用窗口上，跟随浅色主题会读不清
        NSColor.black.withAlphaComponent(0.55).setFill()
        path.fill()
        text.draw(at: CGPoint(x: badge.minX + padding.width, y: badge.minY + padding.height),
                  withAttributes: attributes)
    }
}
