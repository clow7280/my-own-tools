import AppKit

/// 单个分区。坐标为屏幕可用区域内的比例值（0~1），原点在左上角。
struct ZoneSpec: Codable {
    var name: String?
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

struct LayoutConfig: Codable {
    /// 内置显示器（MacBook 屏幕）布局
    var builtin: [ZoneSpec]
    /// 外接显示器默认布局
    var external: [ZoneSpec]
    /// 按显示器名称（系统设置中显示的名称）指定布局，优先级最高
    var displays: [String: [ZoneSpec]]?
}

enum LayoutStore {
    static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/myowntool/layouts.json")

    /// 默认配置：内置屏左右对半；外接屏为「主区 + 右栏 + 底部三格」。
    static let defaultJSON = """
    {
      "builtin": [
        { "name": "左半屏", "x": 0,   "y": 0, "w": 0.5, "h": 1 },
        { "name": "右半屏", "x": 0.5, "y": 0, "w": 0.5, "h": 1 }
      ],
      "external": [
        { "name": "1·主区", "x": 0,      "y": 0,      "w": 0.6667, "h": 0.6667 },
        { "name": "2·右栏", "x": 0.6667, "y": 0,      "w": 0.3333, "h": 0.6667 },
        { "name": "A·底左", "x": 0,      "y": 0.6667, "w": 0.3333, "h": 0.3333 },
        { "name": "B·底中", "x": 0.3333, "y": 0.6667, "w": 0.3334, "h": 0.3333 },
        { "name": "C·底右", "x": 0.6667, "y": 0.6667, "w": 0.3333, "h": 0.3333 }
      ]
    }
    """

    private(set) static var config: LayoutConfig = decodeDefault()
    /// 最近一次（热）重载时间，供设置页展示
    private(set) static var lastLoaded: Date?

    private static var watcher: DispatchSourceFileSystemObject?
    /// 重挂进行中标记，见 remount()
    private static var isRemounting = false

    private static func decodeDefault() -> LayoutConfig {
        try! JSONDecoder().decode(LayoutConfig.self, from: Data(defaultJSON.utf8))
    }

    /// 比例值比较的容差。
    /// 配置里的比例是手写的三位小数，0.6667 + 0.3333 这类加法在 Double 里未必正好等于 1，
    /// 严格按 <= 1 判定会把默认布局自己判成越屏；1e-6 折算到 4K 宽度不足 0.01 像素，
    /// 既能吸收舍入误差，也不会放过真正越界的数值。
    private static let ratioEpsilon = 1e-6

    /// 剔除会让 zoneRects 算出退化或越屏矩形的分区。
    /// 这些矩形会经 Accessibility 直接套到其他 App 的窗口上，宁可丢弃也不能放行。
    private static func validZones(_ zones: [ZoneSpec]) -> [ZoneSpec] {
        zones.filter { zone in
            // NaN 与 ±inf 参与比较时所有判定都会失效，必须先挡掉
            guard zone.x.isFinite, zone.y.isFinite, zone.w.isFinite, zone.h.isFinite else { return false }
            // 容差内视作等于 0 或等于 1：宽高不得退化，起点不得为负，右下角不得越出可用区域
            guard zone.w > ratioEpsilon, zone.h > ratioEpsilon else { return false }
            guard zone.x >= -ratioEpsilon, zone.y >= -ratioEpsilon else { return false }
            return zone.x + zone.w <= 1 + ratioEpsilon && zone.y + zone.h <= 1 + ratioEpsilon
        }
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
        let area = screen.visibleFrame
        return specs(for: screen).map { spec in
            CGRect(
                x: area.minX + area.width * spec.x,
                y: area.minY + area.height * (1 - spec.y - spec.h),
                width: area.width * spec.w,
                height: area.height * spec.h
            )
        }
    }
}
