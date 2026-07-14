import AppKit

/// AI 订阅用量监视器：定时（默认 5 分钟）并发拉取 Claude / Codex 用量，主线程回调。
/// 用量变化慢，且 Claude 端点要求 ≥180s 轮询，故间隔取 300s。
final class AIUsageMonitor {
    static let interval: TimeInterval = 300

    private(set) var claude = AIUsage(error: "加载中…")
    private(set) var codex = AIUsage(error: "加载中…")
    private(set) var gemini = AIUsage(error: "未接入")   // 需先安装 Antigravity，暂占位

    /// 每轮拉取完成后在主线程回调
    var onUpdate: (() -> Void)?

    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "myowntool.aiusage", qos: .utility)

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: Self.interval, leeway: .seconds(10))
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func refresh() {
        let group = DispatchGroup()
        group.enter()
        ClaudeUsageReader.fetch { [weak self] usage in
            self?.claude = usage
            group.leave()
        }
        group.enter()
        CodexUsageReader.fetch { [weak self] usage in
            self?.codex = usage
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            self?.onUpdate?()
        }
    }
}
