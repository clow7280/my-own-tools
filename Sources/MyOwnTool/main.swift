import AppKit

if CommandLine.arguments.contains("--stats-probe") {
    StatsProbe.run()
}
if CommandLine.arguments.contains("--ai-probe") {
    AIProbe.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// 菜单栏应用，不显示 Dock 图标
app.setActivationPolicy(.accessory)
app.run()
