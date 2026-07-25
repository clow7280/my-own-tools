import AppKit
import ApplicationServices

/// 辅助功能窗口元素的轻量封装。所有坐标均为 AX（左上原点）全局坐标系。
struct AXWindow {
    let element: AXUIElement

    private static let systemWide = AXUIElementCreateSystemWide()

    /// 标题栏判定带高：命中点距窗口顶边不超过此值才算点在标题栏上
    private static let titleBarHeight: CGFloat = 30

    /// 查找指定位置的窗口（point 为 AX 坐标）
    static func window(atAX point: CGPoint) -> AXWindow? {
        hitTest(atAX: point)?.window
    }

    /// 查找指定位置标题栏所属的窗口（point 为 AX 坐标）。
    /// 命中按钮（关闭/缩放、工具栏按钮）或命中点不在窗口顶部标题栏带内时返回 nil。
    static func titleBarWindow(atAX point: CGPoint) -> AXWindow? {
        guard let hit = hitTest(atAX: point) else { return nil }
        if role(of: hit.element) == kAXButtonRole { return nil }
        guard let frame = hit.window.frame else { return nil }
        let depth = point.y - frame.minY      // AX 坐标 minY 即窗口顶边
        guard depth >= 0, depth <= titleBarHeight else { return nil }
        return hit.window
    }

    /// 命中测试：返回命中元素与其所属窗口，供不同手势自行判定命中区域
    private static func hitTest(atAX point: CGPoint) -> (element: AXUIElement, window: AXWindow)? {
        // 缩短 AX 调用超时：事件监视器回调内不能被无响应的目标 App 长时间阻塞
        AXUIElementSetMessagingTimeout(systemWide, 0.3)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let element = hit else { return nil }

        // 排除自己的窗口（例如分区标记层）
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() { return nil }

        guard let window = resolveWindow(from: element) else { return nil }
        return (element, window)
    }

    private static func resolveWindow(from hit: AXUIElement) -> AXWindow? {
        var element = hit
        if role(of: element) == kAXWindowRole { return found(element) }

        // 命中元素通常带有所属窗口属性
        if let window = copyElement(of: element, attribute: kAXWindowAttribute),
           role(of: window) == kAXWindowRole {
            return found(window)
        }

        // 兜底：沿父链向上查找
        for _ in 0..<24 {
            guard let parent = copyElement(of: element, attribute: kAXParentAttribute) else { return nil }
            if role(of: parent) == kAXWindowRole { return found(parent) }
            element = parent
        }
        return nil
    }

    private static func found(_ element: AXUIElement) -> AXWindow {
        AXUIElementSetMessagingTimeout(element, 0.3)
        return AXWindow(element: element)
    }

    var frame: CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef,
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID() else { return nil }

        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// 部分应用需要按「尺寸→位置→尺寸」的顺序设置才能贴合目标区域
    func setFrame(_ rect: CGRect) {
        setSize(rect.size)
        setPosition(rect.origin)
        setSize(rect.size)
    }

    private func setPosition(_ point: CGPoint) {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    private func setSize(_ size: CGSize) {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    private static func role(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func copyElement(of element: AXUIElement, attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let result = value,
              CFGetTypeID(result) == AXUIElementGetTypeID() else { return nil }
        return (result as! AXUIElement)
    }
}
