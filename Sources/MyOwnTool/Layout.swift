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

    private static func decodeDefault() -> LayoutConfig {
        try! JSONDecoder().decode(LayoutConfig.self, from: Data(defaultJSON.utf8))
    }

    /// 从配置文件加载；文件不存在或解析失败时回退到默认布局
    static func load() {
        lastLoaded = Date()
        guard let data = try? Data(contentsOf: configURL),
              let parsed = try? JSONDecoder().decode(LayoutConfig.self, from: data) else {
            config = decodeDefault()
            return
        }
        config = parsed
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
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { load() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
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
