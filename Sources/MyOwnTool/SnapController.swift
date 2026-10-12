import AppKit
import StatsCore

/// 监听 Shift 窗口手势：按住 Shift 拖动时显示配置分区以及「全屏 / 专注」目标；
/// 同时按住 Option 可把经过的连续分区组合成一个矩形目标，松手后吸附到当前目标。
/// 长按进入分割线编辑的手势在 LayoutEditController，优先级与让位规则见那里。
///
/// 主修饰键选 Shift 而非 Option：Option-点按另一 App 的窗口会触发系统的
/// 「隐藏当前 App」行为，规避它需要能改写事件流的 CGEventTap，而主动式 tap
/// 会给全局鼠标事件增加一跳延迟；Shift 没有窗口级的系统互动，
/// 这里仍只用只读的 NSEvent 全局监视器，Option 仅在 Shift 拖动已成立后扩展目标。
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

    /// 分割线编辑模式期间挂起，由 LayoutEditController 置位。
    /// 两个 Shift 手势里编辑模式优先级最高：进入编辑后本控制器让位，
    /// 此时的 Shift 拖拽只用来拖分割线，不再吸附窗口；退出编辑模式即恢复。
    /// 挂起时顺手清掉进行中的会话，免得恢复后接上一个早已过时的拖拽。
    var isSuspended = false {
        didSet {
            guard isSuspended, isSuspended != oldValue else { return }
            cancel()
        }
    }

    private struct DragSession {
        let window: AXWindow
        let initialFrame: CGRect      // AX 坐标
        var confirmedMoving = false
        var target: SnapTarget?
        var extendedTarget: SnapTarget?
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
        guard isEnabled, !isSuspended else { return }
        let shiftHeld = event.modifierFlags.contains(.shift)
        let optionHeld = event.modifierFlags.contains(.option)

        switch event.type {
        case .leftMouseDown:
            session = nil
            guard shiftHeld else { break }
            beginSession()
        case .leftMouseDragged:
            guard shiftHeld else {
                if overlay.isVisible { pauseOverlay() }
                return
            }
            if session == nil { beginSession() }
            updateSession(optionHeld: optionHeld)
        case .leftMouseUp:
            finish(commit: shiftHeld)
        case .flagsChanged:
            // 拖动过程中松开 Shift 即取消，可再次按下恢复
            if !shiftHeld {
                if overlay.isVisible { pauseOverlay() }
            } else if session?.confirmedMoving == true {
                // 鼠标不动时按下或松开 Option，也要立即切换多分区与单分区预览。
                updateSession(optionHeld: optionHeld)
            }
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

    private func updateSession(optionHeld: Bool) {
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
        let target = overlay.target(at: mouse, extending: optionHeld ? current.extendedTarget : nil)
        if optionHeld, let target, case .zones = target.kind {
            current.extendedTarget = target
        } else {
            // 松开 Option、跨屏、经过空洞或命中特殊目标都会结束本轮累计。
            current.extendedTarget = nil
        }
        current.target = target
        overlay.highlight(current.target)
        session = current
    }

    private func finish(commit: Bool) {
        let ended = session
        overlay.hide()
        session = nil
        guard commit, let ended, ended.confirmedMoving, let target = ended.target else { return }
        let appliedFrame = Coords.cocoaToAX(target.rect)
        ended.window.setFrame(appliedFrame)
    }

    /// Shift 松开：隐藏标记并清空吸附目标，但保留会话，重新按下 Shift 可继续
    private func pauseOverlay() {
        overlay.hide()
        session?.target = nil
        session?.extendedTarget = nil
    }

    private func cancel() {
        overlay.hide()
        session = nil
    }
}
