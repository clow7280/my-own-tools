import Foundation

/// 区分后台刷新与明确的用户操作。后台任务不得弹出钥匙串授权 UI；
/// 菜单中的手动刷新和命令行探针可以请求一次交互式凭证读取。
public enum AIUsageFetchContext: Sendable {
    case automatic
    case userInitiated

    public var allowsCredentialPrompt: Bool {
        self == .userInitiated
    }
}

public enum AIStrategyAvailability: Sendable {
    case available
    case unavailable(AIUsageFailure)
}

public protocol AIUsageFetchStrategy: Sendable {
    var id: String { get }
    var kind: AIUsageFetchKind { get }
    func availability(context: AIUsageFetchContext) async -> AIStrategyAvailability
    func fetch(context: AIUsageFetchContext) async throws -> AIUsageFetchResult
    func shouldFallback(after failure: AIUsageFailure) -> Bool
}

public extension AIUsageFetchStrategy {
    func availability(context _: AIUsageFetchContext) async -> AIStrategyAvailability { .available }
    func shouldFallback(after _: AIUsageFailure) -> Bool { false }
}

public struct AIUsageFetchPipeline: Sendable {
    private let providerID: AIProviderID
    private let strategies: [any AIUsageFetchStrategy]

    public init(providerID: AIProviderID, strategies: [any AIUsageFetchStrategy]) {
        self.providerID = providerID
        self.strategies = strategies
    }

    public func fetch(context: AIUsageFetchContext = .automatic) async -> AIUsageFetchOutcome {
        var attempts: [AIUsageFetchAttempt] = []
        var lastExecutedFailure: AIUsageFailure?
        var lastAvailabilityFailure: AIUsageFailure?

        for strategy in self.strategies {
            if Task.isCancelled {
                let failure = AIUsageFailure(.cancelled, "请求已取消")
                return AIUsageFetchOutcome(result: .failure(failure), attempts: attempts)
            }

            let availability = await strategy.availability(context: context)
            if Task.isCancelled {
                let failure = AIUsageFailure(.cancelled, "请求已取消")
                return AIUsageFetchOutcome(result: .failure(failure), attempts: attempts)
            }
            switch availability {
            case .available:
                break
            case let .unavailable(failure):
                lastAvailabilityFailure = failure
                attempts.append(AIUsageFetchAttempt(
                    strategyID: strategy.id,
                    kind: strategy.kind,
                    wasAvailable: false,
                    failure: failure))
                continue
            }

            do {
                let result = try await strategy.fetch(context: context)
                try Task.checkCancellation()
                guard result.snapshot.providerID == self.providerID else {
                    throw AIUsageFailure(.schemaChanged, "数据源返回了错误的提供方标识")
                }
                guard result.snapshot.hasData else {
                    throw AIUsageFailure(.schemaChanged, "服务返回成功，但没有可识别的用量窗口")
                }
                attempts.append(AIUsageFetchAttempt(
                    strategyID: strategy.id,
                    kind: strategy.kind,
                    wasAvailable: true,
                    failure: nil))
                return AIUsageFetchOutcome(result: .success(result), attempts: attempts)
            } catch is CancellationError {
                let failure = AIUsageFailure(.cancelled, "请求已取消")
                attempts.append(AIUsageFetchAttempt(
                    strategyID: strategy.id,
                    kind: strategy.kind,
                    wasAvailable: true,
                    failure: failure))
                return AIUsageFetchOutcome(result: .failure(failure), attempts: attempts)
            } catch {
                let failure = (error as? AIUsageFailure)
                    ?? AIUsageFailure(.unavailable, error.localizedDescription)
                lastExecutedFailure = failure
                attempts.append(AIUsageFetchAttempt(
                    strategyID: strategy.id,
                    kind: strategy.kind,
                    wasAvailable: true,
                    failure: failure))
                if strategy.shouldFallback(after: failure) { continue }
                return AIUsageFetchOutcome(result: .failure(failure), attempts: attempts)
            }
        }

        let failure = lastExecutedFailure ?? lastAvailabilityFailure
            ?? AIUsageFailure(.unavailable, "没有可用的用量数据源")
        return AIUsageFetchOutcome(result: .failure(failure), attempts: attempts)
    }

    /// 阻塞式凭证、SQLite 与文件读取均在 utility task 中运行；完成线程不作保证。
    @discardableResult
    public func fetch(
        context: AIUsageFetchContext = .automatic,
        _ completion: @escaping @Sendable (AIUsageFetchOutcome) -> Void)
        -> Task<Void, Never>
    {
        Task.detached(priority: .utility) {
            completion(await self.fetch(context: context))
        }
    }
}

public struct AIProviderRefreshPolicy: Sendable {
    public let minimumAutomaticInterval: TimeInterval

    public init(minimumAutomaticInterval: TimeInterval) {
        self.minimumAutomaticInterval = max(1, minimumAutomaticInterval)
    }
}

public struct AIProviderDescriptor: Sendable {
    public let id: AIProviderID
    public let displayName: String
    public let refreshPolicy: AIProviderRefreshPolicy
    public let pipeline: AIUsageFetchPipeline

    public init(
        id: AIProviderID,
        displayName: String,
        refreshPolicy: AIProviderRefreshPolicy,
        strategies: [any AIUsageFetchStrategy])
    {
        self.id = id
        self.displayName = displayName
        self.refreshPolicy = refreshPolicy
        self.pipeline = AIUsageFetchPipeline(providerID: id, strategies: strategies)
    }
}

/// App、探针和 UI 装配共同使用的唯一 provider 清单。
public enum AIProviderRegistry {
    public static let descriptors: [AIProviderDescriptor] = [
        CodexAIProvider.descriptor,
        ClaudeAIProvider.descriptor,
        OpenCodeAIProvider.descriptor,
    ]

    public static func descriptor(for id: AIProviderID) -> AIProviderDescriptor? {
        self.descriptors.first { $0.id == id }
    }
}
