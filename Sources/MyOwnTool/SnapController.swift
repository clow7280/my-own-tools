import AppKit

/// 监听「按住 Shift 拖动窗口」手势：拖动时显示分区标记，松手时把窗口吸附到所在分区。
///
/// 修饰键选 Shift 而非 Option：Option-点按另一 App 的窗口会触发系统的
/// 「隐藏当前 App」行为，规避它需要能改写事件流的 CGEventTap，而主动式 tap
/// 会给全局鼠标事件增加一跳延迟；Shift 没有窗口级的系统互动，
/// 用只读的 NSEvent 全局监视器即可，不影响系统事件投递。
final class SnapController {
    private var eventMonitor: Any?
    private let overlay = OverlayManager()

    var isEnabled = true {
        didSet { if !isEnabled { cancel() } }
    }

    private struct DragSession {
        let window: AXWindow
        let initialFrame: CGRect      // AX 坐标
        var confirmedMoving = false
        var target: (screen: NSScreen, zoneIndex: Int, rect: CGRect)?
    }
    private var session: DragSession?

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
            if shiftHeld { beginSession() }
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
    }
}
