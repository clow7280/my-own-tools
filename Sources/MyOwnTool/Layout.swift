import AppKit
import StatsCore

/// 分区、配置结构与纯几何判定在 StatsCore，便于离线校验；
/// 其余文件不必各自 import 即可继续按原名引用
typealias ZoneSpec = StatsCore.ZoneSpec
typealias LayoutConfig = StatsCore.LayoutConfig

enum LayoutStore {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/myowntool/layouts.json")

    /// 默认配置：内置屏左右对半；外接屏为「主区 + 右栏 + 底部三格」。
    static let defaultJSON = LayoutConfig.defaultJSON

    private(set) static var config: LayoutConfig = decodeDefault()
    /// 最近一次（热）重载时间，供设置页展示
    private(set) static var lastLoaded: Date?

    private static var watcher: DispatchSourceFileSystemObject?
    /// 重挂进行中标记，见 remount()
    private static var isRemounting = false

    private static func decodeDefault() -> LayoutConfig {
        try! JSONDecoder().decode(LayoutConfig.self, from: Data(defaultJSON.utf8))
    }

    private static func validZones(_ zones: [ZoneSpec]) -> [ZoneSpec] {
        LayoutGeometry.validZones(zones)
    }

    /// 逐数组校验用户配置。默认布局满足同一套判定，可直接当兜底来源。
    private static func sanitized(_ parsed: LayoutConfig, fallback: LayoutConfig) -> LayoutConfig {
        var result = parsed
        // 单个坏分区只丢它自己；整组为空说明该场景一个可吸附区域都没有，
        // 拖拽时会毫无反馈，此时按默认布局兜底
        let builtin = validZones(parsed.builtin)
        result.builtin = builtin.isEmpty ? fallback.builtin : builtin
        let external = validZones(parsed.external)
        result.external = external.isEmpty ? fallback.external : external
        if let displays = parsed.displays {
            // 具名布局在默认配置里没有对应项，整组为空时移除该键，
            // 让 specs(for:) 按屏幕类型回落到 builtin / external，而不是留下空数组
            result.displays = displays.compactMapValues { zones in
                let valid = validZones(zones)
                return valid.isEmpty ? nil : valid
            }
        }
        return result
    }

    /// 从配置文件加载；文件不存在、解析失败或分区数值非法时回退到默认布局
    static func load() {
        lastLoaded = Date()
        let fallback = decodeDefault()
        guard let data = try? Data(contentsOf: configURL),
              let parsed = try? JSONDecoder().decode(LayoutConfig.self, from: data) else {
            config = fallback
            return
        }
        config = sanitized(parsed, fallback: fallback)
    }

    /// 首次编辑配置时生成默认文件
    static func writeDefaultIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: configURL.path) else { return }
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? defaultJSON.write(to: configURL, atomically: true, encoding: .utf8)
    }

    /// 分割线编辑写回：更新该屏幕对应的配置段并持久化。
    /// 重新编码会规范化格式并丢弃未知字段，配置文件以本程序写出的结构为准。
    ///
    /// 这是唯一会覆盖用户配置的入口，只在用户拖动过分割线并松开 Shift 时调用；
    /// 写盘前先过一遍 load() 用的同一套数值校验，任何一个分区不合格就整体放弃，
    /// 免得写出一份自己下一秒热重载时又会丢弃的配置。
    static func save(specs: [ZoneSpec], for screen: NSScreen) {
        let normalized = specs.map { $0.normalizedForStorage() }
        guard !normalized.isEmpty, validZones(normalized).count == normalized.count else { return }

        var cfg = config
        let name = screen.localizedName
        if cfg.displays?[name] != nil {
            cfg.displays?[name] = normalized
        } else if LayoutProvider.isBuiltin(screen) {
            cfg.builtin = normalized
        } else {
            cfg.external = normalized
        }
        config = cfg
        lastLoaded = Date()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(cfg) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 原子写只在目录内建临时文件再改名，对监视目录的 source 报的是 .write 而非 .rename，
        // 所以走的是热重载分支、不会误触 remount()；
        // 由此触发的 load() 只更新内存配置，不会再写盘，写-读-写不成环
        try? data.write(to: configURL, options: .atomic)
        startWatching()     // 目录可能刚创建，补挂监视
    }

    /// 配置热重载：监视配置目录，保存后自动重载。
    /// 编辑器保存多为原子替换（rename），监视目录比监视单个文件可靠；
    /// 目录尚不存在时静默跳过，生成默认文件后再调用即可生效。
    static func startWatching() {
        guard watcher == nil else { return }
        let fd = open(configURL.deletingLastPathComponent().path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            // 目录被删除、改名或被同步工具整体替换后，fd 仍指向已消失的旧 inode，
            // 只监听 .write 会静默失效，必须一并监听这几类事件才能察觉并换挂
            eventMask: [.write, .delete, .rename, .revoke],
            queue: .main
        )
        // 事件种类只能在回调里读，闭包对 source 的强引用会在 cancel 后由 libdispatch 释放
        source.setEventHandler {
            let events = source.data
            if events.contains(.write) { load() }
            if !events.isDisjoint(with: [.delete, .rename, .revoke]) { remount() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    /// 目录 inode 失效后换挂到新目录上；目录尚未重建时保持静默，
    /// 设置页「打开文件」走 writeDefaultIfMissing() + startWatching() 仍能把监视救回来。
    private static func remount() {
        guard !isRemounting else { return }
        isRemounting = true
        // fd 的所有权始终在 source 上，cancel handler 里只 close 一次；置空后不会再被 cancel
        watcher?.cancel()
        watcher = nil
        // 删除与替换会连着抛出多个事件，异步延后一跳让这一轮事件收敛，
        // 也避免在事件回调里同步建新 source 形成递归重挂；
        // 新目录不存在时 startWatching() 自己会静默返回，不会自旋重试
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            isRemounting = false
            startWatching()
            // 旧 inode 上的写事件已经丢失，重挂后补读一次；
            // 目录真的没了就按既有语义回退默认布局，不写任何文件
            load()
        }
    }
}

enum LayoutProvider {
    static func isBuiltin(_ screen: NSScreen) -> Bool {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return false
        }
        return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
    }

    static func specs(for screen: NSScreen) -> [ZoneSpec] {
        let cfg = LayoutStore.config
        if let named = cfg.displays?[screen.localizedName] { return named }
        return isBuiltin(screen) ? cfg.builtin : cfg.external
    }

    /// 分区在 Cocoa 全局坐标系下的矩形（基于 visibleFrame，自动避开菜单栏和 Dock）
    static func zoneRects(for screen: NSScreen) -> [CGRect] {
        LayoutGeometry.rects(for: specs(for: screen), in: screen.visibleFrame)
    }
}
