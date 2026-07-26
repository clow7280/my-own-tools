import AppKit

/// 监听 Shift 窗口手势：按住 Shift 拖动时显示分区标记、松手吸附到所在分区；
/// Shift + 双击标题栏则对该窗口依次执行 居中 → 填充 → 还原。
///
/// 修饰键选 Shift 而非 Option：Option-点按另一 App 的窗口会触发系统的
/// 「隐藏当前 App」行为，规避它需要能改写事件流的 CGEventTap，而主动式 tap
/// 会给全局鼠标事件增加一跳延迟；Shift 没有窗口级的系统互动，
/// 用只读的 NSEvent 全局监视器即可，不影响系统事件投递。
final class SnapController {
    private var eventMonitor: Any?
    private let overlay = OverlayManager()

    private static let enabledKey = "SnapEnabled"

    /// 拖拽分屏默认开启，但 `bool(forKey:)` 在键不存在时返回 false，恰好与默认值相反，
    /// 直接取会让首次启动的分屏是关的；所以先用 `object(forKey:)` 区分「从没存过」和「存过 false」。
    private static var storedIsEnabled: Bool {
        guard UserDefaults.standard.object(forKey: self.enabledKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: self.enabledKey)
    }

    var isEnabled = SnapController.storedIsEnabled {
        didSet {
            if !isEnabled { cancel() }
            // 设置页每次重建开关都会回写一次，值没变就不必打扰 UserDefaults
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
        }
    }

    private struct DragSession {
        let window: AXWindow
        let initialFrame: CGRect      // AX 坐标
        var confirmedMoving = false
        var target: (screen: NSScreen, zoneIndex: Int, rect: CGRect)?
    }
    private var session: DragSession?

    /// Shift + 双击标题栏的布局循环状态，只保留最近一个窗口，不持久化
    private struct TitleBarCycle {
        enum Stage { case centered, filled }
        let window: AXWindow
        let originalFrame: CGRect     // AX 坐标，首次触发前的窗口位置
        var stage: Stage              // 已经应用的阶段
        var appliedFrame: CGRect      // AX 坐标，最近一次设置后窗口实际所在位置
    }
    private var titleBarCycle: TitleBarCycle?

    /// 判定「窗口仍停在我们上次摆放的位置」的容差
    private static let cycleTolerance: CGFloat = 4

    func start() {
        guard eventMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handle(event)
        }
    }

    private func handle(_ event: NSEvent) {
        guard isEnabled else { return }
        let shiftHeld = event.modifierFlags.contains(.shift)

        switch event.type {
        case .leftMouseDown:
            session = nil
            guard shiftHeld else { break }
            // 双击标题栏走布局循环；随后清空会话，避免双击第一次 mouseDown 建立的会话影响拖拽判定
            if event.clickCount == 2, cycleTitleBarLayout() {
                session = nil
                break
            }
            beginSession()
        case .leftMouseDragged:
            guard shiftHeld else {
                if overlay.isVisible { pauseOverlay() }
                return
            }
            if session == nil { beginSession() }
            updateSession()
        case .leftMouseUp:
            finish(commit: shiftHeld)
        case .flagsChanged:
            // 拖动过程中松开 Shift 即取消，可再次按下恢复
            if !shiftHeld, overlay.isVisible { pauseOverlay() }
        default:
            break
        }
    }

    /// 记录当前鼠标位置下的窗口，作为候选拖拽对象
    private func beginSession() {
        let axPoint = Coords.cocoaToAX(NSEvent.mouseLocation)
        guard let window = AXWindow.window(atAX: axPoint), let frame = window.frame else { return }
        session = DragSession(window: window, initialFrame: frame)
    }

    private func updateSession() {
        guard var current = session else { return }

        // 窗口位置真的变化才认定为「正在拖动窗口」，避免误伤窗口内部的 Shift 操作（如扩展选区）
        if !current.confirmedMoving {
            guard let frame = current.window.frame else {
                session = nil
                return
            }
            let moved = abs(frame.minX - current.initialFrame.minX) + abs(frame.minY - current.initialFrame.minY)
            guard moved > 4 else {
                session = current
                return
            }
            current.confirmedMoving = true
        }

        if !overlay.isVisible { overlay.show() }

        let mouse = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let rects = LayoutProvider.zoneRects(for: screen)
            if let index = rects.firstIndex(where: { $0.contains(mouse) }) {
                current.target = (screen, index, rects[index])
                overlay.highlight(screen: screen, zoneIndex: index)
            } else {
                current.target = nil
                overlay.highlight(screen: nil, zoneIndex: nil)
            }
        } else {
            current.target = nil
            overlay.highlight(screen: nil, zoneIndex: nil)
        }
        session = current
    }

    private func finish(commit: Bool) {
        let ended = session
        overlay.hide()
        session = nil
        guard commit, let ended, ended.confirmedMoving, let target = ended.target else { return }
        ended.window.setFrame(Coords.cocoaToAX(target.rect))
    }

    /// Shift 松开：隐藏标记并清空吸附目标，但保留会话，重新按下 Shift 可继续
    private func pauseOverlay() {
        overlay.hide()
        session?.target = nil
    }

    private func cancel() {
        overlay.hide()
        session = nil
        titleBarCycle = nil
    }

    // MARK: - Shift + 双击标题栏

    /// 对同一窗口依次执行 居中 → 填充 → 还原，还原后再触发从居中重新开始。
    /// 语义对齐系统 Window 菜单的 Center 与 Fill，但直接用 AX 设置 frame，不调用菜单项也不注入事件。
    /// 返回是否命中标题栏并执行了动作。
    private func cycleTitleBarLayout() -> Bool {
        let axPoint = Coords.cocoaToAX(NSEvent.mouseLocation)
        guard let window = AXWindow.titleBarWindow(atAX: axPoint),
              let frame = window.frame,
              let visible = visibleFrame(forWindowAt: frame) else { return false }

        // 换了窗口，或窗口已偏离我们上次摆放的位置（用户手动移动或触发了其他布局）：重新开始循环
        let ongoing = titleBarCycle.flatMap { cycle -> TitleBarCycle? in
            guard CFEqual(cycle.window.element, window.element),
                  maxOffset(frame, cycle.appliedFrame) <= Self.cycleTolerance else { return nil }
            return cycle
        }
        let originalFrame = ongoing?.originalFrame ?? frame

        let target: CGRect
        let nextStage: TitleBarCycle.Stage?
        switch ongoing?.stage {
        case nil:
            target = centeredFrame(of: frame, in: visible)
            nextStage = .centered
        case .centered?:
            target = Coords.cocoaToAX(visible)
            nextStage = .filled
        case .filled?:
            target = originalFrame
            nextStage = nil
        }

        window.setFrame(target)
        guard let nextStage else {
            titleBarCycle = nil
            return true
        }
        // 记录设置后窗口的实际位置：应用可能按最小尺寸或字符网格夹取，
        // 直接存目标值会把这类夹取误判成用户手动移动，导致循环走不下去
        titleBarCycle = TitleBarCycle(window: window, originalFrame: originalFrame,
                                      stage: nextStage, appliedFrame: window.frame ?? target)
        return true
    }

    /// 窗口中心所在屏的可用区域（Cocoa 坐标）；找不到所属屏时退回鼠标所在屏
    private func visibleFrame(forWindowAt axFrame: CGRect) -> CGRect? {
        let cocoaFrame = Coords.axToCocoa(axFrame)
        let center = CGPoint(x: cocoaFrame.midX, y: cocoaFrame.midY)
        let screen = NSScreen.screens.first(where: { NSMouseInRect(center, $0.frame, false) })
            ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) })
            ?? NSScreen.main
        return screen?.visibleFrame
    }

    /// 保持窗口尺寸并在可用区域内居中；尺寸超出可用区域时先夹取尺寸。返回值为 AX 坐标
    private func centeredFrame(of axFrame: CGRect, in visible: CGRect) -> CGRect {
        let size = CGSize(width: min(axFrame.width, visible.width),
                          height: min(axFrame.height, visible.height))
        let rect = CGRect(x: visible.midX - size.width / 2,
                          y: visible.midY - size.height / 2,
                          width: size.width, height: size.height)
        return Coords.cocoaToAX(rect)
    }

    /// 两个矩形在位置与尺寸上的最大偏差
    private func maxOffset(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY),
            abs(a.width - b.width), abs(a.height - b.height))
    }
}
