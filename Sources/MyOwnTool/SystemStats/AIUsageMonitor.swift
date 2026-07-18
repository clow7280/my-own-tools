import AppKit

/// AI 订阅用量监视器：定时（默认 5 分钟）并发拉取 ChatGPT / Claude 用量，
/// 也支持单家手动刷新（弹窗 AI 卡片的刷新按钮）。状态只在主线程读写。
/// 用量变化慢，且 Claude 端点要求 ≥180s 轮询，故最小间隔取 180s、默认 300s。
final class AIUsageMonitor {
    /// 自动刷新间隔下限（秒）：Claude 端点要求 ≥180s 轮询
    static let minInterval: TimeInterval = 180
    static let defaultInterval: TimeInterval = 300
    /// 设置页可选的间隔预设（秒），均不低于 minInterval
    static let intervalOptions: [TimeInterval] = [180, 300, 600, 1800]

    private static let intervalKey = "AIUsageRefreshInterval"

    /// 持久化的自动刷新间隔；低于下限或未设置时回落默认值
    static var interval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: intervalKey)
            return stored >= minInterval ? stored : defaultInterval
        }
        set { UserDefaults.standard.set(max(minInterval, newValue), forKey: intervalKey) }
    }

    /// 数据过期阈值预设（秒）：失败持续且距上次成功超过该时长时，叹号由黄转红
    static let staleOptions: [TimeInterval] = [600, 1800, 3600, 7200]
    static let defaultStaleInterval: TimeInterval = 1800

    private static let staleKey = "AIUsageStaleInterval"

    /// 持久化的数据过期阈值；未设置或非法时回落默认值
    static var staleInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: staleKey)
            return stored > 0 ? stored : defaultStaleInterval
        }
        set { UserDefaults.standard.set(newValue, forKey: staleKey) }
    }

    private var currentInterval: TimeInterval = AIUsageMonitor.interval

    enum Provider: CaseIterable {
        case chatGPT
        case claude
    }

    private(set) var chatGPT = AIUsage(error: "加载中…")
    private(set) var claude = AIUsage(error: "加载中…")
    private(set) var chatGPTUpdatedAt: Date?
    private(set) var claudeUpdatedAt: Date?

    // 失败叹号徽章所需状态：最近一次成功快照、成功时间、当前失败段起点
    private var lastGood: [Provider: AIUsage] = [:]
    private var lastSuccessAt: [Provider: Date] = [:]
    private var firstFailureAt: [Provider: Date] = [:]
    private var healths: [Provider: AIHealth] = [:]

    /// 任一家数据更新后在主线程回调
    var onUpdate: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private var inFlight: Set<Provider> = []

    func usage(_ provider: Provider) -> AIUsage {
        provider == .chatGPT ? chatGPT : claude
    }

    func updatedAt(_ provider: Provider) -> Date? {
        provider == .chatGPT ? chatGPTUpdatedAt : claudeUpdatedAt
    }

    /// 首次拉取完成前保持 ok（不画徽章）
    func health(_ provider: Provider) -> AIHealth {
        healths[provider] ?? .ok
    }

    /// 菜单栏环的展示数据：最近一次失败时回落到上次成功快照，
    /// 但 Codex 离线快照这类"失败但带数据"的结果优先展示
    func displayUsage(_ provider: Provider) -> AIUsage {
        let latest = usage(provider)
        return latest.hasData ? latest : (lastGood[provider] ?? latest)
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 2, repeating: currentInterval, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in
            Provider.allCases.forEach { self?.refresh($0) }
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 更新自动刷新间隔（主线程调用）：持久化并按新间隔重建定时器
    func setInterval(_ seconds: TimeInterval) {
        let clamped = max(Self.minInterval, seconds)
        guard clamped != currentInterval else { return }
        Self.interval = clamped
        currentInterval = clamped
        guard timer != nil else { return }
        stop()
        start()
    }

    /// 拉取单家用量（主线程调用）；同一家的进行中请求不重复发起
    func refresh(_ provider: Provider) {
        guard !inFlight.contains(provider) else { return }
        inFlight.insert(provider)

        let apply: (AIUsage) -> Void = { [weak self] usage in
            DispatchQueue.main.async {
                guard let self else { return }
                switch provider {
                case .chatGPT: self.chatGPT = usage
                case .claude: self.claude = usage
                }
                if provider == .chatGPT { self.chatGPTUpdatedAt = Date() } else { self.claudeUpdatedAt = Date() }
                self.applyHealth(provider, usage: usage)
                self.inFlight.remove(provider)
                self.onUpdate?()
            }
        }
        // 凭证读取（含 Keychain 子进程）可能阻塞数秒，放后台队列发起
        DispatchQueue.global(qos: .utility).async {
            switch provider {
            case .chatGPT: CodexUsageReader.fetch(apply)
            case .claude: ClaudeUsageReader.fetch(apply)
            }
        }
    }

    /// 拉取完成时评估健康状态（主线程调用）。
    /// error 非空即视为失败（含离线快照）；红色判定以上次成功为基准，
    /// 从未成功过时以当前失败段起点为基准。
    private func applyHealth(_ provider: Provider, usage: AIUsage) {
        let now = Date()
        guard usage.error != nil else {
            lastGood[provider] = usage
            lastSuccessAt[provider] = now
            firstFailureAt[provider] = nil
            healths[provider] = .ok
            return
        }
        if firstFailureAt[provider] == nil { firstFailureAt[provider] = now }
        let reference = lastSuccessAt[provider] ?? firstFailureAt[provider]!
        healths[provider] = now.timeIntervalSince(reference) > Self.staleInterval ? .stale : .warning
    }
}
