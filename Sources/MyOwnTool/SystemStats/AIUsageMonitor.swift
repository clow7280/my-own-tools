import AIUsageCore
import AppKit

/// Registry 驱动的 AI 用量监视器。所有状态只在主线程读写，provider fetch 在后台执行。
@MainActor
final class AIUsageMonitor {
    static let minInterval: TimeInterval = 180
    static let defaultInterval: TimeInterval = 300
    static let intervalOptions: [TimeInterval] = [180, 300, 600, 1800]

    private static let intervalKey = "AIUsageRefreshInterval"

    /// 刷新定时器允许系统推迟触发的时间。
    private static let timerLeeway: TimeInterval = 10

    /// 跳过判断的余量。重复定时器的下一次 deadline 锚定在初始 deadline 上，
    /// 某次触发被 leeway 推迟后，它与下一次触发的间隔会短于设定周期，
    /// 余量必须覆盖这段抖动，否则整个周期会被误判为“刚刚刷新过”而跳过。
    private static let tickTolerance: TimeInterval = 15

    /// 单次刷新的整体上限。网络路径每个 HTTP 请求自带 15 秒超时，但本地路径
    /// （钥匙串读取、OpenCode 的 SQLite 查询、Codex 的 rollout 扫描）没有任何超时，
    /// 卡住就再也不会回调。取值需高于最慢的合法链路：OpenCode 手动刷新要串行试完
    /// 浏览器候选、取工作区再逐个取用量页，命令行探针给这条链路留的上限是 45 秒，
    /// 留出余量取 60 秒；同时远低于最小刷新间隔 180 秒，卡死的提供方最迟下个周期恢复。
    private static let refreshTimeout: TimeInterval = 60

    static var interval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: self.intervalKey)
            return stored >= self.minInterval ? stored : self.defaultInterval
        }
        set { UserDefaults.standard.set(max(self.minInterval, newValue), forKey: self.intervalKey) }
    }

    static let staleOptions: [TimeInterval] = [600, 1800, 3600, 7200]
    static let defaultStaleInterval: TimeInterval = 1800
    private static let staleKey = "AIUsageStaleInterval"

    static var staleInterval: TimeInterval {
        get {
            let stored = UserDefaults.standard.double(forKey: self.staleKey)
            return stored > 0 ? stored : self.defaultStaleInterval
        }
        set { UserDefaults.standard.set(max(1, newValue), forKey: self.staleKey) }
    }

    private let descriptors = AIProviderRegistry.descriptors
    private var states: [AIProviderID: AIProviderState]
    private var generations: [AIProviderID: Int] = [:]
    private var tasks: [AIProviderID: Task<Void, Never>] = [:]
    private var watchdogs: [AIProviderID: DispatchSourceTimer] = [:]
    private var currentInterval = AIUsageMonitor.interval
    private var refreshTimer: DispatchSourceTimer?
    private var healthTimer: DispatchSourceTimer?
    private var wakeObserver: NSObjectProtocol?

    /// 任一家状态变化后在主线程回调。
    var onUpdate: (() -> Void)?

    init() {
        self.states = Dictionary(uniqueKeysWithValues: self.descriptors.map { ($0.id, AIProviderState()) })
    }

    func state(_ providerID: AIProviderID) -> AIProviderState {
        self.states[providerID] ?? AIProviderState()
    }

    func start() {
        guard self.refreshTimer == nil else { return }
        self.installRefreshTimer(firstDeadline: .now() + 2)

        let healthTimer = DispatchSource.makeTimerSource(queue: .main)
        healthTimer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        healthTimer.setEventHandler { [weak self] in
            Task { @MainActor in self?.reevaluateHealth() }
        }
        healthTimer.resume()
        self.healthTimer = healthTimer

        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshAll(bypassUserInterval: true, context: .automatic)
                }
            }
    }

    func stop() {
        self.refreshTimer?.cancel()
        self.refreshTimer = nil
        self.healthTimer?.cancel()
        self.healthTimer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        self.tasks.values.forEach { $0.cancel() }
        self.tasks.removeAll()
        self.watchdogs.values.forEach { $0.cancel() }
        self.watchdogs.removeAll()
        for descriptor in self.descriptors {
            self.generations[descriptor.id, default: 0] += 1
            self.states[descriptor.id]?.isRefreshing = false
        }
        self.onUpdate?()
    }

    func setInterval(_ seconds: TimeInterval) {
        let clamped = max(Self.minInterval, seconds)
        guard clamped != self.currentInterval else { return }
        Self.interval = clamped
        self.currentInterval = clamped
        guard self.refreshTimer != nil else { return }
        self.refreshTimer?.cancel()
        self.refreshTimer = nil
        self.installRefreshTimer(firstDeadline: .now() + clamped)
    }

    func setStaleInterval(_ seconds: TimeInterval) {
        Self.staleInterval = seconds
        self.reevaluateHealth()
    }

    func refresh(
        _ providerID: AIProviderID,
        context: AIUsageFetchContext = .userInitiated)
    {
        guard let descriptor = AIProviderRegistry.descriptor(for: providerID),
              self.states[providerID]?.isRefreshing != true
        else { return }

        self.generations[providerID, default: 0] += 1
        let generation = self.generations[providerID, default: 0]
        self.states[providerID]?.isRefreshing = true
        // 按发起时刻计时。若等到完成回调再记录，一次耗时数秒的拉取就会让下一个
        // 定时器周期落在最小间隔之内被跳过，实际刷新退化成两倍周期。
        self.states[providerID]?.lastAttemptAt = Date()
        self.onUpdate?()

        // 先装看门狗再发起拉取，避免完成回调抢在装设之前落地而留下无人取消的定时器
        self.installWatchdog(providerID, generation: generation)
        let task = descriptor.pipeline.fetch(context: context) { [weak self] outcome in
            Task { @MainActor in
                guard let self, self.generations[providerID] == generation else { return }
                self.tasks[providerID] = nil
                self.clearWatchdog(providerID)
                self.apply(outcome, providerID: providerID)
            }
        }
        self.tasks[providerID] = task
    }

    /// isRefreshing 只在完成回调里复位，strategy 一旦不返回，自动刷新和手动刷新
    /// 都会被互斥 guard 永久挡住、刷新按钮一直转，只能重启应用；看门狗是唯一的解锁手段。
    private func installWatchdog(_ providerID: AIProviderID, generation: Int) {
        self.clearWatchdog(providerID)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + Self.refreshTimeout, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.fireWatchdog(providerID, generation: generation)
            }
        }
        timer.resume()
        self.watchdogs[providerID] = timer
    }

    private func clearWatchdog(_ providerID: AIProviderID) {
        self.watchdogs[providerID]?.cancel()
        self.watchdogs[providerID] = nil
    }

    private func fireWatchdog(_ providerID: AIProviderID, generation: Int) {
        // 与完成回调共用同一个 generation 判断：stop() 和新一轮 refresh 都会推进它，
        // 让这次开火失效。正常完成不推进 generation，改由 watchdogs 里是否还有条目兜底：
        // cancel 之后已经投递到主队列的 handler 仍会执行一次，光看 generation 会误开火。
        guard self.watchdogs[providerID] != nil,
              self.generations[providerID] == generation
        else { return }
        self.clearWatchdog(providerID)
        // 再推进一格，让卡住的那次拉取即使事后回调也会被当作过期结果丢弃
        self.generations[providerID, default: 0] += 1
        self.tasks[providerID]?.cancel()
        self.tasks[providerID] = nil
        let failure = AIUsageFailure(
            .timeout,
            "拉取超过 \(Int(Self.refreshTimeout)) 秒仍未返回，已中止本次刷新")
        // 走正常的 apply 路径，健康度、叹号徽章和错误文案才能一并更新；
        // 卡在哪个 strategy 无从判断，attempts 留空而不是沿用上一轮的记录
        self.apply(
            AIUsageFetchOutcome(result: .failure(failure), attempts: []),
            providerID: providerID)
    }

    private func installRefreshTimer(firstDeadline: DispatchTime) {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: firstDeadline,
            repeating: self.currentInterval,
            leeway: .seconds(Int(Self.timerLeeway)))
        timer.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.refreshAll(bypassUserInterval: false, context: .automatic)
            }
        }
        timer.resume()
        self.refreshTimer = timer
    }

    private func refreshAll(
        bypassUserInterval: Bool,
        context: AIUsageFetchContext)
    {
        let now = Date()
        for descriptor in self.descriptors {
            if let lastAttempt = self.states[descriptor.id]?.lastAttemptAt {
                let required = bypassUserInterval
                    ? descriptor.refreshPolicy.minimumAutomaticInterval
                    : max(self.currentInterval, descriptor.refreshPolicy.minimumAutomaticInterval)
                guard now.timeIntervalSince(lastAttempt) >= required - Self.tickTolerance
                else { continue }
            }
            self.refresh(descriptor.id, context: context)
        }
    }

    private func apply(_ outcome: AIUsageFetchOutcome, providerID: AIProviderID) {
        var state = self.states[providerID] ?? AIProviderState()
        let now = Date()
        state.isRefreshing = false
        state.attempts = outcome.attempts

        switch outcome.result {
        case let .success(result):
            let shouldAdoptSnapshot = result.source.quality != .cached
                || state.snapshot == nil
                || result.snapshot.capturedAt > (state.lastDataAt ?? .distantPast)
            if shouldAdoptSnapshot {
                state.snapshot = result.snapshot
                state.source = result.source
                state.lastDataAt = result.snapshot.capturedAt
            }
            state.partialFailures = result.partialFailures
            if result.source.quality == .cached {
                let cause = outcome.attempts.compactMap(\.failure).first
                    ?? AIUsageFailure(.unavailable, "在线用量暂不可用")
                let message = shouldAdoptSnapshot
                    ? "在线用量暂不可用，显示本地会话快照：\(cause.message)"
                    : "在线用量暂不可用，保留较新的现有数据：\(cause.message)"
                state.failure = AIUsageFailure(
                    cause.kind,
                    message)
                if state.firstFailureAt == nil { state.firstFailureAt = now }
            } else {
                state.failure = nil
                state.firstFailureAt = nil
                state.lastSuccessAt = now
            }
        case let .failure(failure):
            state.failure = failure
            state.partialFailures = []
            if state.firstFailureAt == nil { state.firstFailureAt = now }
        }

        state.health = self.health(for: state, now: now)
        self.states[providerID] = state
        self.onUpdate?()
    }

    private func reevaluateHealth() {
        let now = Date()
        var changed = false
        for descriptor in self.descriptors {
            guard var state = self.states[descriptor.id] else { continue }
            let health = self.health(for: state, now: now)
            if state.health != health {
                state.health = health
                self.states[descriptor.id] = state
                changed = true
            }
        }
        if changed { self.onUpdate?() }
    }

    private func health(for state: AIProviderState, now: Date) -> AIHealth {
        guard state.failure != nil else { return .ok }
        let newestData = [state.lastSuccessAt, state.lastDataAt].compactMap { $0 }.max()
        let reference = newestData ?? state.firstFailureAt ?? now
        return now.timeIntervalSince(reference) > Self.staleInterval ? .stale : .warning
    }
}
