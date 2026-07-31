import AppKit

if CommandLine.arguments.contains("--stats-probe") {
    StatsProbe.run()
}

// AppKit 的入口固定运行在主线程；显式建立 MainActor 边界，避免把该约束
// 隐藏在各个控制器的 unchecked Sendable 声明中。
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // 菜单栏应用，不显示 Dock 图标
    app.setActivationPolicy(.accessory)
    app.run()
}
