import AppKit
import StatsCore

/// 监听 Shift 窗口手势：按住 Shift 拖动时显示配置分区以及「全屏 / 专注」目标，
/// 松手后把窗口吸附到当前目标。
/// 长按进入分割线编辑的手势在 LayoutEditController，优先级与让位规则见那里。
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
        let focusSize: CGSize
        var confirmedMoving = false
        var target: SnapTarget?
    }
    private var session: DragSession?

    /// 仅记录由本工具应用过的全屏状态，用来让下一次专注恢复全屏前尺寸。
    /// AX 元素没有适合作为 Dictionary key 的稳定公开标识，因此保留一个有上限的小数组，
    /// 通过 CFEqual 匹配同一窗口；关闭窗口留下的失效元素也不会无限累积。
    private struct FullScreenRecord {
        let window: AXWindow
        let focusSize: CGSize
        let appliedFrame: CGRect      // AX 坐标，考虑目标 App 自身的尺寸夹取
    }
    private var fullScreenRecords: [FullScreenRecord] = []
    private static let fullScreenRecordLimit = 32

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
        session = DragSession(
            window: window,
            initialFrame: frame,
            focusSize: resolvedFocusSize(for: window, currentFrame: frame))
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

        if !overlay.isVisible { overlay.show(focusSize: current.focusSize) }

        let mouse = NSEvent.mouseLocation
        current.target = overlay.target(at: mouse)
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
        switch target.kind {
        case .fullScreen:
            rememberFullScreen(
                for: ended.window,
                focusSize: ended.focusSize,
                appliedFrame: ended.window.frame ?? appliedFrame)
        case .zone(_), .focus:
            forgetFullScreen(for: ended.window)
        }
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

    private func resolvedFocusSize(for window: AXWindow, currentFrame: CGRect) -> CGSize {
        guard let index = fullScreenRecords.lastIndex(where: {
            CFEqual($0.window.element, window.element)
        }) else { return currentFrame.size }

        let record = fullScreenRecords[index]
        guard let restored = LayoutGeometry.restoredFocusSize(
            currentFrame: currentFrame,
            appliedFullScreenFrame: record.appliedFrame,
            savedSize: record.focusSize)
        else {
            // 窗口已被用户或其他布局改动，旧的全屏前尺寸不再代表当前意图。
            fullScreenRecords.remove(at: index)
            return currentFrame.size
        }

        // 命中记录移到末尾，使数组上限淘汰最久未使用的窗口。
        if index != fullScreenRecords.index(before: fullScreenRecords.endIndex) {
            fullScreenRecords.remove(at: index)
            fullScreenRecords.append(record)
        }
        return restored
    }

    private func rememberFullScreen(for window: AXWindow, focusSize: CGSize, appliedFrame: CGRect) {
        forgetFullScreen(for: window)
        fullScreenRecords.append(FullScreenRecord(
            window: window,
            focusSize: focusSize,
            appliedFrame: appliedFrame))
        if fullScreenRecords.count > Self.fullScreenRecordLimit {
            fullScreenRecords.removeFirst(fullScreenRecords.count - Self.fullScreenRecordLimit)
        }
    }

    private func forgetFullScreen(for window: AXWindow) {
        fullScreenRecords.removeAll { CFEqual($0.window.element, window.element) }
    }
}
