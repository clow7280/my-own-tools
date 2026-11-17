import CoreGraphics

/// Dock 停靠的屏幕边，取值与 `com.apple.dock` 的 `orientation` 偏好一致
public enum DockEdge: String {
    case left, bottom, right
}

/// 判定 Dock 当前位于哪块屏幕。
/// 所有矩形为 Cocoa 全局坐标（左下原点），frames 与 visibleFrames 按同一顺序排列。
public enum DockPlacement {
    /// 判定时忽略的浮点误差
    private static let tolerance: CGFloat = 0.5

    /// 返回 Dock 所在屏幕的下标，没有屏幕时返回 nil。
    ///
    /// 停在左右两侧时，Dock 只会出现在整个桌面最外侧的屏幕上，按屏幕位置即可确定。
    /// 停在底部时，Dock 跟着用户把指针推到哪块屏幕的底边而换屏，位置看不出来，
    /// 只能看哪块屏幕的可用区域在底边让出了空间。
    /// 让位看不出来时（例如 Dock 已自动隐藏），沿用上次判定的屏幕，再不行取主屏（下标 0）。
    public static func hostIndex(edge: DockEdge, frames: [CGRect], visibleFrames: [CGRect],
                                 lastHost: Int?) -> Int? {
        guard !frames.isEmpty, frames.count == visibleFrames.count else { return nil }
        let indices = Array(frames.indices)

        let candidates: [Int]
        switch edge {
        case .left:
            let outer = frames.map(\.minX).min()!
            candidates = indices.filter { abs(frames[$0].minX - outer) <= tolerance }
        case .right:
            let outer = frames.map(\.maxX).max()!
            candidates = indices.filter { abs(frames[$0].maxX - outer) <= tolerance }
        case .bottom:
            candidates = indices
        }

        let inset = candidates.filter { reservesSpace(edge: edge, frame: frames[$0], visible: visibleFrames[$0]) }
        let pool = inset.isEmpty ? candidates : inset
        if let lastHost, pool.contains(lastHost) { return lastHost }
        return pool[0]
    }

    /// 可用区域是否在 Dock 所在边让出了空间
    private static func reservesSpace(edge: DockEdge, frame: CGRect, visible: CGRect) -> Bool {
        switch edge {
        case .left: return visible.minX > frame.minX + tolerance
        case .right: return visible.maxX < frame.maxX - tolerance
        case .bottom: return visible.minY > frame.minY + tolerance
        }
    }
}
