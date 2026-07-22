import Foundation

enum ClaudeAIProvider {
    static let descriptor = AIProviderDescriptor(
        id: .claude,
        displayName: "Claude",
        refreshPolicy: AIProviderRefreshPolicy(minimumAutomaticInterval: 180),
        strategies: [ClaudeOAuthUsageStrategy()])
}

private struct ClaudeCredentials: Sendable {
    let accessToken: String
    let rawPlan: String?
    let multiplier: Int?
    let expiresAt: Date?

    func isExpired(at date: Date = Date()) -> Bool {
        self.expiresAt.map { date >= $0 } ?? false
    }
}

private enum ClaudeCredentialStore {
    private final class CredentialCache: @unchecked Sendable {
        private let lock = NSLock()
        private var credentials: ClaudeCredentials?
        private var rejectedToken: String?

        func current(now: Date = Date()) -> ClaudeCredentials? {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.credentials?.isExpired(at: now) == true { self.credentials = nil }
            return self.credentials
        }

        func store(_ credentials: ClaudeCredentials) {
            self.lock.lock()
            self.credentials = credentials
            if self.rejectedToken != credentials.accessToken { self.rejectedToken = nil }
            self.lock.unlock()
        }

        func isRejected(_ credentials: ClaudeCredentials) -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.rejectedToken == credentials.accessToken
        }

        func reject(_ credentials: ClaudeCredentials) {
            self.lock.lock()
            if self.credentials?.accessToken == credentials.accessToken { self.credentials = nil }
            self.rejectedToken = credentials.accessToken
            self.lock.unlock()
        }
    }

    private static let cache = CredentialCache()

    static func load(context: AIUsageFetchContext) throws -> ClaudeCredentials {
        if !context.allowsCredentialPrompt, let cached = self.cache.current() { return cached }

        let url = AIKnownPaths.homeDirectory
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent(".credentials.json", isDirectory: false)
        let fileData = try? Data(contentsOf: url)
        var foundCandidate = false
        var foundExpired = false
        var foundRejected = false

        func accept(_ data: Data) -> ClaudeCredentials? {
            guard let credentials = self.parse(data) else { return nil }
            if self.cache.isRejected(credentials) {
                foundRejected = true
                return nil
            }
            if credentials.isExpired() {
                foundExpired = true
                return nil
            }
            self.cache.store(credentials)
            return credentials
        }

        // 后台优先读取文件；只有文件不可用时才做一次禁止 UI 的 Keychain 查询。
        if !context.allowsCredentialPrompt, let fileData {
            foundCandidate = true
            if let credentials = accept(fileData) { return credentials }
        }
        if let keychainData = AISecureCredentialReader.readGenericPassword(
            service: "Claude Code-credentials",
            allowsUserInteraction: context.allowsCredentialPrompt)
        {
            foundCandidate = true
            if let credentials = accept(keychainData) { return credentials }
        }
        if context.allowsCredentialPrompt, let fileData {
            foundCandidate = true
            if let credentials = accept(fileData) { return credentials }
        }
        if foundExpired || foundRejected {
            throw AIUsageFailure(.unauthorized, "Claude 登录已过期，请运行 claude auth login")
        }
        guard foundCandidate else {
            let message = context.allowsCredentialPrompt
                ? "未找到 Claude Code 登录凭证"
                : "未找到可无交互读取的 Claude Code 凭证，请手动刷新授权"
            throw AIUsageFailure(.credentialMissing, message)
        }
        throw AIUsageFailure(.credentialMissing, "Claude Code 凭证中没有可用的 OAuth token")
    }

    static func reject(_ credentials: ClaudeCredentials) {
        self.cache.reject(credentials)
    }

    private static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = (oauth["accessToken"] as? String)?.aiSafeHeaderValue,
              !token.isEmpty
        else {
            return nil
        }

        let tier = oauth["rateLimitTier"] as? String
        let rawPlan = oauth["subscriptionType"] as? String ?? tier
        let planText = [rawPlan, tier].compactMap { $0 }.joined(separator: " ").lowercased()
        let multiplier: Int? = if planText.contains("20x") || planText.contains("20×") {
            20
        } else if planText.contains("5x") || planText.contains("5×") {
            5
        } else {
            nil
        }
        return ClaudeCredentials(
            accessToken: token,
            rawPlan: rawPlan,
            multiplier: multiplier,
            expiresAt: AIJSON.date(oauth["expiresAt"]))
    }
}

private enum ClaudeCLI {
    private static let candidates: [String] = {
        let home = AIKnownPaths.homeDirectory.path
        return [
            home + "/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }()

    static let userAgent: String = {
        guard let result = AIBoundedProcessRunner.run(
            executableCandidates: ClaudeCLI.candidates,
            arguments: ["--version"],
            timeout: 3,
            captureOutput: true),
            result.status == 0,
            let output = String(data: result.output, encoding: .utf8),
            let version = output.range(of: #"[0-9]+(?:\.[0-9]+){1,3}"#, options: .regularExpression)
        else {
            return "claude-code/1.0.0"
        }
        return "claude-code/" + String(output[version])
    }()

}

private struct ClaudeOAuthUsageStrategy: AIUsageFetchStrategy {
    let id = "claude.oauth"
    let kind = AIUsageFetchKind.oauth

    func fetch(context: AIUsageFetchContext) async throws -> AIUsageFetchResult {
        try await self.request(ClaudeCredentialStore.load(context: context))
    }

    private func request(_ credentials: ClaudeCredentials) async throws -> AIUsageFetchResult {
        var request = URLRequest(
            url: URL(string: "https://api.anthropic.com/api/oauth/usage")!,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(ClaudeCLI.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await AIURLSessionHTTPTransport.shared.send(
            request,
            allowedHosts: ["api.anthropic.com"])
        switch response.statusCode {
        case 200:
            let snapshot = try ClaudeUsageParser.parse(
                data: response.data,
                rawPlan: credentials.rawPlan,
                multiplier: credentials.multiplier)
            return AIUsageFetchResult(
                snapshot: snapshot,
                source: AIUsageSource(
                    id: self.id,
                    label: "OAuth",
                    kind: .oauth,
                    quality: .live))
        case 401:
            ClaudeCredentialStore.reject(credentials)
            throw AIUsageFailure(.unauthorized, "Claude 登录已失效，请运行 claude auth login")
        case 403:
            throw AIUsageFailure(.permissionDenied, "Claude 拒绝访问当前账号的用量数据")
        case 429:
            throw AIUsageFailure(.rateLimited, "Claude 用量接口暂时限流")
        default:
            throw AIUsageFailure(.httpStatus, "Claude 请求失败（HTTP \(response.statusCode)）")
        }
    }
}

public enum ClaudeUsageParser {
    public static func parse(data: Data, rawPlan: String?, multiplier: Int?, now: Date = Date()) throws
        -> AIUsageSnapshot
    {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageFailure(.schemaChanged, "Claude 返回了无法解析的用量数据")
        }

        var windows: [AIUsageWindow] = []
        let fiveHourExplicitlyAbsent = json["five_hour"] == nil || json["five_hour"] is NSNull
        if !fiveHourExplicitlyAbsent {
            guard let five = json["five_hour"] as? [String: Any],
                  let fraction = AIJSON.fraction(percent: five["utilization"] ?? five["used_percent"])
            else {
                throw AIUsageFailure(.schemaChanged, "Claude 的 5 小时窗口格式已变化")
            }
            windows.append(AIUsageWindow(
                id: .session,
                value: .measured(fraction),
                resetsAt: AIJSON.date(five["resets_at"] ?? five["reset_at"])))
        }

        let sevenDayExplicitlyAbsent = json["seven_day"] == nil || json["seven_day"] is NSNull
        if !sevenDayExplicitlyAbsent {
            guard let seven = json["seven_day"] as? [String: Any],
                  let fraction = AIJSON.fraction(percent: seven["utilization"] ?? seven["used_percent"])
            else {
                throw AIUsageFailure(.schemaChanged, "Claude 的 7 天窗口格式已变化")
            }
            windows.append(AIUsageWindow(
                id: .weekly,
                value: .measured(fraction),
                resetsAt: AIJSON.date(seven["resets_at"] ?? seven["reset_at"])))
        }

        // Claude 可能暂时取消 5 小时限制；显式建模，避免 nil 同时表示缺数据。
        if fiveHourExplicitlyAbsent,
           windows.contains(where: { $0.id == .weekly })
        {
            windows.insert(AIUsageWindow(id: .session, value: .notEnforced), at: 0)
        }

        var extras: [AIUsageWindow] = []
        if let limits = json["limits"] as? [Any] {
            for limit in limits.compactMap({ $0 as? [String: Any] })
            where (limit["kind"] as? String) == "weekly_scoped"
                && (limit["group"] as? String) == "weekly"
            {
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = self.nonEmpty(model["display_name"] as? String),
                      !self.isAllModels(name: name, id: model["id"] as? String),
                      let fraction = AIJSON.fraction(percent: limit["percent"] ?? limit["utilization"])
                else { continue }
                self.appendExtra(
                    key: self.nonEmpty(model["id"] as? String) ?? name,
                    title: name + " 专属",
                    raw: limit,
                    fraction: fraction,
                    extras: &extras)
            }
        }
        let legacyDefinitions: [(keys: [String], title: String)] = [
            (["seven_day_sonnet"], "Sonnet 专属"),
            (["seven_day_opus"], "Opus 专属"),
            (["seven_day_oauth_apps"], "OAuth Apps 专属"),
            ([
                "seven_day_routines", "seven_day_claude_routines", "claude_routines",
                "routines", "routine", "seven_day_cowork", "cowork",
            ], "Claude Routines"),
        ]
        for definition in legacyDefinitions {
            guard let populated = definition.keys.lazy.compactMap({ key -> (String, [String: Any])? in
                guard let raw = json[key] as? [String: Any] else { return nil }
                return (key, raw)
            }).first,
                  let fraction = AIJSON.fraction(
                      percent: populated.1["utilization"] ?? populated.1["used_percent"])
            else { continue }
            self.appendExtra(
                key: populated.0,
                title: definition.title,
                raw: populated.1,
                fraction: fraction,
                extras: &extras)
        }

        if let extraUsage = json["extra_usage"] as? [String: Any],
           extraUsage["is_enabled"] as? Bool == true,
           let fraction = self.extraUsageFraction(extraUsage)
        {
            extras.append(AIUsageWindow(
                id: AIUsageWindowID(rawValue: "claude-spend-limit"),
                title: "月度消费限额",
                value: .measured(fraction)))
        }

        guard windows.contains(where: \.hasData) || extras.contains(where: \.hasData) else {
            throw AIUsageFailure(.schemaChanged, "Claude 返回成功，但没有可识别的用量窗口")
        }
        return AIUsageSnapshot(
            providerID: .claude,
            windows: windows,
            extraWindows: extras,
            plan: self.plan(raw: rawPlan, multiplier: multiplier),
            capturedAt: now)
    }

    private static func appendExtra(
        key: String,
        title: String,
        raw: [String: Any],
        fraction: Double,
        extras: inout [AIUsageWindow])
    {
        let id = AIUsageWindowID(rawValue: "claude-" + self.slug(key))
        guard !extras.contains(where: { $0.id == id || $0.title == title }) else { return }
        extras.append(AIUsageWindow(
            id: id,
            title: title,
            value: .measured(fraction),
            resetsAt: AIJSON.date(raw["resets_at"] ?? raw["reset_at"])))
    }

    private static func isAllModels(name: String, id: String?) -> Bool {
        let names = [name, id].compactMap { $0 }.map(self.slug)
        return names.contains("all-models") || names.contains { $0.hasSuffix("-all-models") }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return if let trimmed, !trimmed.isEmpty { trimmed } else { nil }
    }

    private static func extraUsageFraction(_ extra: [String: Any]) -> Double? {
        if let fraction = AIJSON.fraction(percent: extra["utilization"]) { return fraction }
        guard let used = AIJSON.number(extra["used_credits"]), used.isFinite, used >= 0,
              let limit = AIJSON.number(extra["monthly_limit"]), limit.isFinite, limit > 0
        else { return nil }
        return min(max(used / limit, 0), 1)
    }

    private static func slug(_ value: String) -> String {
        var result = value.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        while result.last == "-" { result.removeLast() }
        return String(result).replacingOccurrences(of: #"-+"#, with: "-", options: .regularExpression)
    }

    private static func plan(raw: String?, multiplier: Int?) -> AIUsagePlan? {
        if multiplier == 20 { return AIUsagePlan(rawValue: raw, displayName: "Max 20×") }
        if multiplier == 5 { return AIUsagePlan(rawValue: raw, displayName: "Max 5×") }
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        let display: String
        if lower.contains("max") { display = "Max" }
        else if lower.contains("enterprise") { display = "Enterprise" }
        else if lower.contains("team") { display = "Team" }
        else if lower.contains("pro") { display = "Pro" }
        else { display = raw.prefix(1).uppercased() + raw.dropFirst() }
        return AIUsagePlan(rawValue: raw, displayName: display)
    }
}
