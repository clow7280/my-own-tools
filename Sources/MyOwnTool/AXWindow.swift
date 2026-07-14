import AppKit
import ApplicationServices

/// 辅助功能窗口元素的轻量封装。所有坐标均为 AX（左上原点）全局坐标系。
struct AXWindow {
    let element: AXUIElement

    private static let systemWide = AXUIElementCreateSystemWide()

    /// 查找指定位置的窗口（point 为 AX 坐标）
    static func window(atAX point: CGPoint) -> AXWindow? {
        // 缩短 AX 调用超时：事件 tap 回调内不能被无响应的目标 App 长时间阻塞
        AXUIElementSetMessagingTimeout(systemWide, 0.3)

        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }

        // 排除自己的窗口（例如分区标记层）
        var pid: pid_t = 0
        if AXUIElementGetPid(element, &pid) == .success, pid == getpid() { return nil }

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
