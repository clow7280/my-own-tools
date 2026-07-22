import Foundation

/// 稳定的提供方标识。使用字符串值而不是封闭 enum，新增厂商时无需修改公共模型。
public struct AIProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let codex = AIProviderID(rawValue: "codex")
    public static let claude = AIProviderID(rawValue: "claude")
    public static let openCode = AIProviderID(rawValue: "opencode-go")
}

/// 提供方内部稳定的窗口标识；展示标题由 AppKit presentation 层决定。
public struct AIUsageWindowID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let session = AIUsageWindowID(rawValue: "session")
    public static let weekly = AIUsageWindowID(rawValue: "weekly")
    public static let monthly = AIUsageWindowID(rawValue: "monthly")
}

public struct AIUsageSegment: Equatable, Sendable {
    public let label: String
    public let date: Date?
    public let value: Double

    public init(label: String, date: Date? = nil, value: Double) {
        self.label = label
        self.date = date
        self.value = value.isFinite ? max(value, 0) : 0
    }
}

public struct AIUsageWindow: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        case measured(Double)
        case notEnforced
        case unavailable
    }

    public let id: AIUsageWindowID
    public var title: String?
    public var value: Value
    public var resetsAt: Date?
    public var segments: [AIUsageSegment]

    public init(
        id: AIUsageWindowID,
        title: String? = nil,
        value: Value,
        resetsAt: Date? = nil,
        segments: [AIUsageSegment] = [])
    {
        self.id = id
        self.title = title
        switch value {
        case let .measured(fraction):
            self.value = .measured(Self.clamp(fraction))
        case .notEnforced:
            self.value = .notEnforced
        case .unavailable:
            self.value = .unavailable
        }
        self.resetsAt = resetsAt
        self.segments = segments
    }

    public var fraction: Double? {
        guard case let .measured(value) = self.value else { return nil }
        return value
    }

    public var hasData: Bool {
        switch self.value {
        case .measured, .notEnforced: true
        case .unavailable: false
        }
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

public struct AIUsagePlan: Equatable, Sendable {
    public let rawValue: String?
    public let displayName: String

    public init(rawValue: String? = nil, displayName: String) {
        self.rawValue = rawValue
        self.displayName = displayName
    }
}

/// 纯成功数据。错误、刷新状态和 fallback 尝试不会写进快照。
public struct AIUsageSnapshot: Equatable, Sendable {
    public let providerID: AIProviderID
    public var windows: [AIUsageWindow]
    public var extraWindows: [AIUsageWindow]
    public var plan: AIUsagePlan?
    public let capturedAt: Date

    public init(
        providerID: AIProviderID,
        windows: [AIUsageWindow],
        extraWindows: [AIUsageWindow] = [],
        plan: AIUsagePlan? = nil,
        capturedAt: Date = Date())
    {
        self.providerID = providerID
        self.windows = windows
        self.extraWindows = extraWindows
        self.plan = plan
        self.capturedAt = capturedAt
    }

    public var hasData: Bool {
        self.windows.contains(where: \.hasData) || self.extraWindows.contains(where: \.hasData)
    }

    public func window(_ id: AIUsageWindowID) -> AIUsageWindow? {
        self.windows.first { $0.id == id }
    }

    public mutating func replaceWindow(_ window: AIUsageWindow) {
        if let index = self.windows.firstIndex(where: { $0.id == window.id }) {
            self.windows[index] = window
        } else {
            self.windows.append(window)
        }
    }
}

public struct AIUsageFailure: Error, LocalizedError, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case credentialMissing
        case unauthorized
        case permissionDenied
        case unavailable
        case network
        case timeout
        case rateLimited
        case httpStatus
        case schemaChanged
        case commandFailed
        case localData
        /// 凭证语法有效，但对应账号/profile 没有目标产品用量；可尝试下一个候选。
        case candidateRejected
        case security
        case cancelled
    }

    public let kind: Kind
    public let message: String

    public init(_ kind: Kind, _ message: String) {
        self.kind = kind
        self.message = message
    }

    public var errorDescription: String? { self.message }
}

public enum AIUsageSourceKind: String, Sendable {
    case oauth
    case web
    case local
}

public enum AIUsageSourceQuality: String, Sendable {
    /// 服务端直接返回的权威窗口。
    case live
    /// 由本机历史按公开额度推算的窗口。
    case estimated
    /// 从历史会话提取的旧快照，仅用于断网降级。
    case cached
}

public struct AIUsageSource: Equatable, Sendable {
    public let id: String
    public let label: String
    public let kind: AIUsageSourceKind
    public let quality: AIUsageSourceQuality

    public init(id: String, label: String, kind: AIUsageSourceKind, quality: AIUsageSourceQuality) {
        self.id = id
        self.label = label
        self.kind = kind
        self.quality = quality
    }
}

public struct AIUsageFetchResult: Sendable {
    public let snapshot: AIUsageSnapshot
    public let source: AIUsageSource
    /// 可选增强数据失败等非终止问题；不会把主快照标记为失败。
    public let partialFailures: [AIUsageFailure]

    public init(
        snapshot: AIUsageSnapshot,
        source: AIUsageSource,
        partialFailures: [AIUsageFailure] = [])
    {
        self.snapshot = snapshot
        self.source = source
        self.partialFailures = partialFailures
    }
}

public enum AIUsageFetchKind: String, Sendable {
    case oauth
    case web
    case local
}

public struct AIUsageFetchAttempt: Sendable {
    public let strategyID: String
    public let kind: AIUsageFetchKind
    public let wasAvailable: Bool
    public let failure: AIUsageFailure?

    public init(
        strategyID: String,
        kind: AIUsageFetchKind,
        wasAvailable: Bool,
        failure: AIUsageFailure?)
    {
        self.strategyID = strategyID
        self.kind = kind
        self.wasAvailable = wasAvailable
        self.failure = failure
    }
}

public struct AIUsageFetchOutcome: Sendable {
    public let result: Result<AIUsageFetchResult, AIUsageFailure>
    public let attempts: [AIUsageFetchAttempt]

    public init(
        result: Result<AIUsageFetchResult, AIUsageFailure>,
        attempts: [AIUsageFetchAttempt])
    {
        self.result = result
        self.attempts = attempts
    }
}
