import AIUsageCore
import AppKit

/// 单家提供方的拉取健康状态（DESIGN.md 环失败叹号徽章）。
enum AIHealth: Equatable {
    case ok
    case warning
    case stale
}

struct AIProviderState {
    var snapshot: AIUsageSnapshot?
    var source: AIUsageSource?
    var lastAttemptAt: Date?
    var lastSuccessAt: Date?
    var lastDataAt: Date?
    var firstFailureAt: Date?
    var failure: AIUsageFailure?
    var partialFailures: [AIUsageFailure] = []
    var attempts: [AIUsageFetchAttempt] = []
    var isRefreshing = false
    var health: AIHealth = .ok
}

struct AIWindowPresentation {
    let id: AIUsageWindowID
    let title: String
}

/// 网络层 descriptor 不依赖 AppKit；颜色、中文标题和菜单栏槽位集中在此处。
struct AIProviderPresentation {
    let id: AIProviderID
    let displayName: String
    let windows: [AIWindowPresentation]
    let ringWindowIDs: [AIUsageWindowID]
    let standardColor: NSColor
    let deepColor: NSColor
    let badgeTextColor: NSColor
    let badgeBackgroundColor: NSColor
    let showsInMenuBar: Bool
}

enum AIProviderPresentationRegistry {
    private static let registered: [AIProviderPresentation] = [
        AIProviderPresentation(
            id: .codex,
            displayName: "ChatGPT",
            windows: [
                AIWindowPresentation(id: .session, title: "5 小时窗口"),
                AIWindowPresentation(id: .weekly, title: "7 天窗口"),
            ],
            ringWindowIDs: [.session, .weekly],
            standardColor: StatsPalette.chatGPT,
            deepColor: StatsPalette.chatGPTDeep,
            badgeTextColor: StatsPalette.chatGPTDeep,
            badgeBackgroundColor: StatsPalette.chatGPTBadgeBG,
            showsInMenuBar: true),
        AIProviderPresentation(
            id: .claude,
            displayName: "Claude",
            windows: [
                AIWindowPresentation(id: .session, title: "5 小时窗口"),
                AIWindowPresentation(id: .weekly, title: "7 天窗口"),
            ],
            ringWindowIDs: [.session, .weekly],
            standardColor: StatsPalette.claude,
            deepColor: StatsPalette.claudeDeep,
            badgeTextColor: StatsPalette.claudeDeep,
            badgeBackgroundColor: StatsPalette.claudeBadgeBG,
            showsInMenuBar: true),
        AIProviderPresentation(
            id: .openCode,
            displayName: "OpenCode",
            windows: [
                AIWindowPresentation(id: .session, title: "滚动窗口"),
                AIWindowPresentation(id: .weekly, title: "每周窗口"),
                AIWindowPresentation(id: .monthly, title: "每月窗口"),
            ],
            ringWindowIDs: [.session, .weekly],
            standardColor: StatsPalette.openCode,
            deepColor: StatsPalette.openCodeDeep,
            badgeTextColor: StatsPalette.openCodeDeep,
            badgeBackgroundColor: StatsPalette.openCodeBadgeBG,
            showsInMenuBar: true),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues:
        AIProviderPresentationRegistry.registered.map { ($0.id, $0) })

    /// 排序和启用范围跟随核心 registry；缺少或多出 presentation 时启动即失败，
    /// 避免新增厂商后后台抓取成功却静默不展示。
    static let all: [AIProviderPresentation] = {
        let coreIDs = AIProviderRegistry.descriptors.map(\.id)
        precondition(
            Set(coreIDs) == Set(AIProviderPresentationRegistry.registered.map(\.id)),
            "AI provider registry 与 presentation registry 不一致")
        return coreIDs.map { id in
            guard let presentation = AIProviderPresentationRegistry.byID[id] else {
                preconditionFailure("AI provider \(id.rawValue) 缺少 presentation")
            }
            if presentation.showsInMenuBar {
                let visibleWindowIDs = Set(presentation.windows.map(\.id))
                precondition(
                    presentation.ringWindowIDs.count == 2
                        && presentation.ringWindowIDs.allSatisfy(visibleWindowIDs.contains),
                    "菜单栏 AI provider \(id.rawValue) 必须声明两个有效环窗口")
            }
            return presentation
        }
    }()

    static var menuBar: [AIProviderPresentation] {
        self.all.filter(\.showsInMenuBar)
    }

    static func presentation(for id: AIProviderID) -> AIProviderPresentation? {
        self.byID[id]
    }
}
