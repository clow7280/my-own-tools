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

    private var currentInterval: TimeInterval = AIUsageMonitor.interval

    enum Provider: CaseIterable {
        case chatGPT
        case claude
    }

    private(set) var chatGPT = AIUsage(error: "加载中…")
    private(set) var claude = AIUsage(error: "加载中…")
    private(set) var chatGPTUpdatedAt: Date?
    private(set) var claudeUpdatedAt: Date?

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
}
