import AppKit
import StatsCore

/// 按 Dock 所在显示器切换系统的「自动隐藏 Dock」。
///
/// macOS 只有一个全局的自动隐藏开关，不能按显示器分别设置；
/// 这里给每块显示器记一个偏好，Dock 落在哪块显示器上就把全局开关切到那块的偏好。
/// 总开关默认关闭，关闭时完全不碰 Dock；关掉总开关也不还原，Dock 保持当时的状态。
///
/// 触发时机：启动、设置页改动、屏幕参数变化（接入或拔出显示器、调整排列、Dock 换屏或改尺寸）。
/// 切换自动隐藏本身也会改变可用区域并再次触发屏幕参数通知，
/// 届时判定结果不变、与系统当前状态一致，不会再写，因此不会循环。
@MainActor
final class DockAutoHideController {
    /// 设置页用的显示器状态
    struct Display {
        let name: String
        let isBuiltin: Bool
        let autoHide: Bool
        let hostsDock: Bool
    }

    private static let enabledKey = "DockAutoHideEnabled"
    private static let displaysKey = "DockAutoHideDisplays"
    /// 接入显示器时屏幕参数通知会连发多次，等它安静下来再判定
    private static let debounce: TimeInterval = 0.5

    private var observer: NSObjectProtocol?
    private var pendingApply: DispatchWorkItem?
    /// 上次判定的 Dock 所在显示器名，底部 Dock 隐藏后看不出位置时沿用
    private var lastHostName: String?

    /// 私有接口缺失（系统改动）时整个功能不可用，设置页据此置灰
    var isAvailable: Bool { CoreDock.isAvailable }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            apply()
        }
    }

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleApply() }
        }
        apply()
    }

    /// 当前已连接显示器的偏好与 Dock 所在位置
    func displays() -> [Display] {
        let screens = NSScreen.screens
        let host = hostScreen(in: screens)
        return screens.map { screen in
            Display(name: screen.localizedName,
                    isBuiltin: LayoutProvider.isBuiltin(screen),
                    autoHide: prefersAutoHide(screen),
                    hostsDock: screen == host)
        }
    }

    func setAutoHide(_ autoHide: Bool, forDisplay name: String) {
        var stored = Self.storedDisplays
        stored[name] = autoHide
        UserDefaults.standard.set(stored, forKey: Self.displaysKey)
        apply()
    }

    private func scheduleApply() {
        pendingApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.apply() }
        }
        pendingApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounce, execute: work)
    }

    private func apply() {
        let screens = NSScreen.screens
        let host = hostScreen(in: screens)
        guard isEnabled, isAvailable, let host else { return }
        let wanted = prefersAutoHide(host)
        if CoreDock.autoHide != wanted {
            CoreDock.autoHide = wanted
        }
    }

    /// 判定 Dock 所在显示器，并记下来供下次看不出位置时沿用
    private func hostScreen(in screens: [NSScreen]) -> NSScreen? {
        let lastHost = lastHostName.flatMap { name in screens.firstIndex { $0.localizedName == name } }
        guard let index = DockPlacement.hostIndex(edge: CoreDock.edge,
                                                  frames: screens.map(\.frame),
                                                  visibleFrames: screens.map(\.visibleFrame),
                                                  lastHost: lastHost) else { return nil }
        lastHostName = screens[index].localizedName
        return screens[index]
    }

    /// 没存过偏好的显示器：内置屏默认自动隐藏，外接屏默认常显
    private func prefersAutoHide(_ screen: NSScreen) -> Bool {
        Self.storedDisplays[screen.localizedName] ?? LayoutProvider.isBuiltin(screen)
    }

    private static var storedDisplays: [String: Bool] {
        UserDefaults.standard.dictionary(forKey: displaysKey) as? [String: Bool] ?? [:]
    }
}

/// Dock 的私有接口与偏好读取。
/// `CoreDockGetAutoHideEnabled` / `CoreDockSetAutoHideEnabled` 位于 ApplicationServices，
/// 与「系统设置 → 桌面与程序坞」的开关等效，立即生效且不需要额外授权；
/// 用 dlsym 运行时查找，未来系统移除时功能降级为不可用，而不是启动失败。
private enum CoreDock {
    private typealias GetFn = @convention(c) () -> Bool
    private typealias SetFn = @convention(c) (Bool) -> Void

    private static let handle = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY)
    private static let getFn: GetFn? = handle.flatMap { dlsym($0, "CoreDockGetAutoHideEnabled") }
        .map { unsafeBitCast($0, to: GetFn.self) }
    private static let setFn: SetFn? = handle.flatMap { dlsym($0, "CoreDockSetAutoHideEnabled") }
        .map { unsafeBitCast($0, to: SetFn.self) }

    static var isAvailable: Bool { getFn != nil && setFn != nil }

    static var autoHide: Bool {
        get { getFn?() ?? false }
        set { setFn?(newValue) }
    }

    /// Dock 停靠边。偏好由 Dock 进程写入，读之前先同步，避免拿到本进程缓存的旧值
    static var edge: DockEdge {
        let domain = "com.apple.dock" as CFString
        CFPreferencesAppSynchronize(domain)
        let raw = CFPreferencesCopyAppValue("orientation" as CFString, domain) as? String
        return raw.flatMap(DockEdge.init(rawValue:)) ?? .bottom
    }
}
