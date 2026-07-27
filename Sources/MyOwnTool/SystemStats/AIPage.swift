import AIUsageCore
import AppKit
import StatsCore

// MARK: - AI 页

/// AI 提供方的展示与交互配置（AppDelegate 装配）
struct AIProviderSpec {
    var presentation: AIProviderPresentation
    var state: () -> AIProviderState
    var refresh: () -> Void
}

/// ChatGPT / Claude / OpenCode 各一张卡片：标题行 + 各订阅窗口与专属模型用量条（设计稿 3b）
final class AIPage: FlippedView {
    private(set) var contentHeight: CGFloat = 0
    private var cards: [ProviderCard] = []

    init(providers: [AIProviderSpec]) {
        super.init(frame: .zero)
        for spec in providers {
            let card = ProviderCard(spec: spec)
            addSubview(card)
            cards.append(card)
        }
        update()
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 重新填充数据并按各卡实际高度重排
    func update() {
        var y: CGFloat = 0
        for card in cards {
            let height = card.apply()
            card.frame = NSRect(x: 0, y: y, width: PageUI.pageWidth, height: height)
            y += height + PageUI.cardGap
        }
        contentHeight = y - PageUI.cardGap
    }

    /// 单家卡片
    private final class ProviderCard: CardView {
        private let spec: AIProviderSpec
        private let nameLabel: NSTextField
        private let updatedLabel = PageUI.label(size: 10, color: .tertiaryLabelColor)
        private let refreshButton = NSButton()
        private let refreshSpinner = NSProgressIndicator()
        private let badge: BadgeView
        private let errorLabel = PageUI.label(size: 11, color: .secondaryLabelColor)
        private var rows: [UsageRow] = []

        private var standard: NSColor { self.spec.presentation.standardColor }
        private var deep: NSColor { self.spec.presentation.deepColor }

        init(spec: AIProviderSpec) {
            self.spec = spec
            nameLabel = PageUI.label(spec.presentation.displayName, size: 13, weight: .semibold)
            badge = BadgeView(
                textColor: spec.presentation.badgeTextColor,
                background: spec.presentation.badgeBackgroundColor)
            super.init(frame: .zero)

            addSubview(nameLabel)
            addSubview(updatedLabel)
            addSubview(errorLabel)
            addSubview(badge)
            errorLabel.maximumNumberOfLines = 0
            errorLabel.lineBreakMode = .byWordWrapping

            refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新")
            refreshButton.bezelStyle = .circular
            refreshButton.controlSize = .small
            refreshButton.target = self
            refreshButton.action = #selector(refreshTapped)
            addSubview(refreshButton)

            refreshSpinner.style = .spinning
            refreshSpinner.controlSize = .small
            refreshSpinner.isDisplayedWhenStopped = false
            refreshSpinner.isHidden = true
            addSubview(refreshSpinner)
        }

        required init?(coder: NSCoder) { fatalError() }

        @objc private func refreshTapped() { spec.refresh() }

        /// 填充数据、重排并返回卡片高度
        func apply() -> CGFloat {
            let state = self.spec.state()
            let usage = state.snapshot
            let hasData = usage?.hasData == true

            // 标题行
            nameLabel.frame = NSRect(x: PageUI.cardPadding, y: 11, width: 120, height: 17)
            nameLabel.sizeToFit()
            nameLabel.setFrameOrigin(NSPoint(x: PageUI.cardPadding, y: 11))
            updatedLabel.stringValue = Self.sourceStatus(state)
            updatedLabel.toolTip = updatedLabel.stringValue
            updatedLabel.frame = NSRect(x: nameLabel.frame.maxX + 7, y: 14, width: 130, height: 13)

            // 刷新按钮固定在最右，订阅徽章排在其左侧
            let buttonSize: CGFloat = 20
            refreshButton.frame = NSRect(x: PageUI.pageWidth - PageUI.cardPadding - buttonSize,
                                         y: 9, width: buttonSize, height: buttonSize)
            refreshSpinner.frame = NSRect(x: refreshButton.frame.midX - 7, y: refreshButton.frame.midY - 7,
                                          width: 14, height: 14)
            let refreshing = state.isRefreshing
            refreshButton.isHidden = refreshing
            refreshButton.isEnabled = !refreshing
            refreshSpinner.isHidden = !refreshing
            if refreshing { refreshSpinner.startAnimation(nil) } else { refreshSpinner.stopAnimation(nil) }

            badge.text = usage?.plan?.displayName ?? ""
            badge.isHidden = badge.text.isEmpty
            badge.setFrameOrigin(NSPoint(x: refreshButton.frame.minX - 6 - badge.frame.width, y: 11))

            var y: CGFloat = 37
            let issue = Self.issueText(state)
            errorLabel.stringValue = issue ?? (hasData ? "" : "暂无数据")
            errorLabel.toolTip = issue
            if !hasData {
                let errorHeight = self.issueHeight(errorLabel.stringValue)
                errorLabel.isHidden = false
                errorLabel.frame = NSRect(
                    x: PageUI.cardPadding,
                    y: y,
                    width: PageUI.innerWidth,
                    height: errorHeight)
                rows.forEach { $0.isHidden = true }
                return y + errorHeight + 11
            }

            // 订阅窗口与扩展窗口；新增厂商只需注册 presentation，无需增加 Kind 分支。
            var configs: [UsageRow.Config] = []
            for item in self.spec.presentation.windows {
                let window = usage?.window(item.id)
                configs.append(.init(
                    title: item.title,
                    fraction: window?.fraction,
                    color: self.standard,
                    striped: window?.value == .notEnforced,
                    caption: Self.resetText(window?.resetsAt),
                    segments: window?.segments ?? []))
            }
            for window in usage?.extraWindows ?? [] {
                configs.append(.init(
                    title: window.title ?? "扩展窗口",
                    fraction: window.fraction,
                    color: self.deep,
                    striped: window.value == .notEnforced,
                    caption: Self.resetText(window.resetsAt),
                    segments: window.segments))
            }

            while rows.count < configs.count {
                let row = UsageRow()
                addSubview(row)
                rows.append(row)
            }
            for (index, row) in rows.enumerated() {
                guard index < configs.count else {
                    row.isHidden = true
                    continue
                }
                row.isHidden = false
                row.frame = NSRect(x: PageUI.cardPadding, y: y, width: PageUI.innerWidth, height: UsageRow.height)
                row.apply(configs[index])
                y += UsageRow.height + 6
            }
            y -= 6
            if let issue {
                let errorHeight = self.issueHeight(issue)
                errorLabel.isHidden = false
                errorLabel.frame = NSRect(
                    x: PageUI.cardPadding,
                    y: y + 6,
                    width: PageUI.innerWidth,
                    height: errorHeight)
                y += errorHeight + 6
            } else {
                errorLabel.isHidden = true
            }
            return y + 11
        }

        private func issueHeight(_ text: String) -> CGFloat {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let bounds = (text as NSString).boundingRect(
                with: NSSize(width: PageUI.innerWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [
                    .font: self.errorLabel.font ?? NSFont.systemFont(ofSize: 11),
                    .paragraphStyle: paragraph,
                ])
            return max(15, ceil(bounds.height))
        }

        private static func relativeTime(_ date: Date?) -> String {
            guard let date else { return "" }
            let seconds = -date.timeIntervalSinceNow
            if seconds < 90 { return "刚刚更新" }
            if seconds < 3600 { return "\(Int(seconds / 60)) 分钟前更新" }
            return "\(Int(seconds / 3600)) 小时前更新"
        }

        private static func sourceStatus(_ state: AIProviderState) -> String {
            let time = self.relativeTime(state.lastDataAt)
            let source: String? = switch state.source?.quality {
            case .live: state.source.map { $0.label + " 实时" }
            case .estimated: state.source?.label ?? "本地估算"
            case .cached: state.source?.label ?? "本地快照"
            case nil: nil
            }
            return [source, time].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }.joined(separator: " · ")
        }

        private static func issueText(_ state: AIProviderState) -> String? {
            var messages: [String] = []
            if let failure = state.failure { messages.append(failure.message) }
            messages.append(contentsOf: state.partialFailures.map { "可选明细：" + $0.message })
            return messages.isEmpty ? nil : messages.joined(separator: "；")
        }

        /// 重置时间：24h 内显示倒计时，否则显示星期与时刻
        private static func resetText(_ date: Date?) -> String {
            guard let date else { return "" }
            let interval = date.timeIntervalSinceNow
            guard interval > 0 else { return "即将重置" }
            if interval < 24 * 3600 {
                let hours = Int(interval) / 3600
                let minutes = (Int(interval) % 3600) / 60
                return hours > 0 ? "\(hours)h \(minutes)m 后重置" : "\(minutes)m 后重置"
            }
            return Self.weekdayFormatter.string(from: date) + " 重置"
        }

        private static let weekdayFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "EEE HH:mm"
            return formatter
        }()
    }

    /// 一条用量：标题 + 百分比 / 进度条 / 重置说明
    private final class UsageRow: FlippedView {
        struct Config {
            var title: String
            var fraction: Double?   // nil + striped = 限额取消；nil + !striped = 无数据
            var color: NSColor
            var striped: Bool
            var caption: String
            var segments: [AIUsageSegment]
        }

        static let height: CGFloat = 36

        private let titleLabel = PageUI.label(size: 11, color: .secondaryLabelColor)
        private let percentLabel = PageUI.label(size: 11, weight: .semibold, mono: true)
        private let bar = UsageBar()
        private let captionLabel = PageUI.label(size: 10, color: .tertiaryLabelColor)

        init() {
            super.init(frame: .zero)
            titleLabel.frame = NSRect(x: 0, y: 0, width: 200, height: 14)
            percentLabel.alignment = .right
            captionLabel.alignment = .right
            addSubview(titleLabel)
            addSubview(percentLabel)
            addSubview(bar)
            addSubview(captionLabel)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func resizeSubviews(withOldSize oldSize: NSSize) {
            super.resizeSubviews(withOldSize: oldSize)
            percentLabel.frame = NSRect(x: bounds.width - 60, y: 0, width: 60, height: 14)
            bar.frame = NSRect(x: 0, y: 17, width: bounds.width, height: 6)
            captionLabel.frame = NSRect(x: bounds.width - 160, y: 26, width: 160, height: 13)
        }

        func apply(_ config: Config) {
            titleLabel.stringValue = config.title
            bar.color = config.color
            bar.striped = config.striped
            bar.fraction = config.fraction ?? 0
            bar.segments = config.segments
            percentLabel.stringValue = config.striped ? "" : config.fraction.map(StatsFormat.percent) ?? "—"
            captionLabel.stringValue = config.caption
            resizeSubviews(withOldSize: bounds.size)
        }
    }
}
