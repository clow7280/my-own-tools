import Foundation

enum CodexAIProvider {
    static let descriptor = AIProviderDescriptor(
        id: .codex,
        displayName: "Codex",
        refreshPolicy: AIProviderRefreshPolicy(minimumAutomaticInterval: 60),
        strategies: [CodexOAuthUsageStrategy(), CodexRolloutUsageStrategy()])
}

private struct CodexCredentials: Sendable {
    let accessToken: String
    let accountID: String?
    let plan: String?
}

/// 只在本机解码 ChatGPT `id_token` 的 payload，取出订阅类型这一个字符串。
/// 解码结果不外发、不写日志，也不读取 claim 中的其他字段。
public enum CodexPlanExtractor {
    private static let claim = "https://api.openai.com/auth"
    private static let maximumTokenLength = 8_192

    public static func plan(fromIDToken token: String?) -> String? {
        guard let token, !token.isEmpty, token.count <= self.maximumTokenLength else { return nil }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let payload = self.decodeBase64URL(String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        let auth = json[self.claim] as? [String: Any]
        guard let raw = (auth?["chatgpt_plan_type"] ?? json["chatgpt_plan_type"]) as? String
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty else { return nil }
        var text = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }
}

private enum CodexCredentialStore {
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexCredentials {
        let url = AIKnownPaths.codexHome(environment: environment).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else {
            throw AIUsageFailure(.credentialMissing, "未找到 Codex 登录凭证")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = ((tokens["access_token"] ?? tokens["accessToken"]) as? String)?.aiSafeHeaderValue,
              !token.isEmpty
        else {
            throw AIUsageFailure(.credentialMissing, "Codex 凭证中没有可用的 OAuth token")
        }
        let account = ((tokens["account_id"] ?? tokens["accountId"]) as? String)?.aiSafeHeaderValue
        return CodexCredentials(
            accessToken: token,
            accountID: account,
            plan: self.plan(tokens: tokens))
    }

    /// 降级到本地会话快照时，`rate_limits` 里没有套餐字段，只能从本机 `id_token` 兜底取值。
    static func localPlan(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let url = AIKnownPaths.codexHome(environment: environment).appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any]
        else { return nil }
        return self.plan(tokens: tokens)
    }

    private static func plan(tokens: [String: Any]) -> String? {
        CodexPlanExtractor.plan(fromIDToken: (tokens["id_token"] ?? tokens["idToken"]) as? String)
    }
}

fileprivate struct CodexUsageEndpoint {
    let usageURL: URL
    let analyticsURL: URL?
    let allowedHost: String
}

/// 与 Codex CLI 共用 `chatgpt_base_url` 语义，但对 URL 做严格 HTTPS 校验。
public enum CodexUsageEndpointResolver {
    private static let defaultBaseURL = "https://chatgpt.com/backend-api"

    public static func resolve(configContents: String?) throws -> URL {
        try self.endpoint(configContents: configContents).usageURL
    }

    fileprivate static func endpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CodexUsageEndpoint
    {
        let url = AIKnownPaths.codexHome(environment: environment).appendingPathComponent("config.toml")
        let contents: String? = {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                  size <= 1_048_576,
                  let data = try? Data(contentsOf: url)
            else { return nil }
            return String(data: data, encoding: .utf8)
        }()
        return try self.endpoint(configContents: contents)
    }

    private static func endpoint(configContents: String?) throws -> CodexUsageEndpoint {
        let configured = configContents.flatMap(self.parseBaseURL) ?? self.defaultBaseURL
        guard var components = URLComponents(string: configured),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil
        else {
            throw AIUsageFailure(.security, "Codex chatgpt_base_url 必须是无凭证、无查询参数的 HTTPS URL")
        }

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let pathParts = path.split(separator: "/")
        guard !pathParts.contains("."), !pathParts.contains("..") else {
            throw AIUsageFailure(.security, "Codex chatgpt_base_url 路径无效")
        }
        let isChatGPTHost = host == "chatgpt.com" || host == "chat.openai.com"
        var usesBackendAPI = pathParts.contains("backend-api")
        if isChatGPTHost, !usesBackendAPI {
            path += "/backend-api"
            usesBackendAPI = true
        }
        let basePath = path == "/" ? "" : path
        components.percentEncodedPath = basePath
            + (usesBackendAPI ? "/wham/usage" : "/api/codex/usage")
        guard let usageURL = components.url else {
            throw AIUsageFailure(.security, "Codex chatgpt_base_url 无法生成用量端点")
        }

        var analyticsURL: URL?
        if usesBackendAPI {
            components.percentEncodedPath = basePath + "/wham/analytics/daily-workspace-usage-counts"
            analyticsURL = components.url
        }
        return CodexUsageEndpoint(
            usageURL: usageURL,
            analyticsURL: analyticsURL,
            allowedHost: host)
    }

    private static func parseBaseURL(from contents: String) -> String? {
        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let uncommented = rawLine.split(
                separator: "#",
                maxSplits: 1,
                omittingEmptySubsequences: false).first ?? rawLine[...]
            let parts = uncommented.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false)
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "chatgpt_base_url"
            else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2,
               (value.first == "\"" && value.last == "\""
                   || value.first == "'" && value.last == "'")
            {
                value.removeFirst()
                value.removeLast()
            }
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

private struct CodexOAuthUsageStrategy: AIUsageFetchStrategy {
    let id = "codex.oauth"
    let kind = AIUsageFetchKind.oauth

    func fetch(context _: AIUsageFetchContext) async throws -> AIUsageFetchResult {
        let credentials = try CodexCredentialStore.load()
        let endpoint = try CodexUsageEndpointResolver.endpoint()
        var request = URLRequest(
            url: endpoint.usageURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue(AIUsageVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await AIURLSessionHTTPTransport.shared.send(
            request,
            allowedHosts: [endpoint.allowedHost])
        switch response.statusCode {
        case 200:
            var snapshot = try CodexUsageParser.parse(data: response.data)
            if snapshot.plan == nil { snapshot.plan = CodexUsageParser.plan(credentials.plan) }
            var partialFailures: [AIUsageFailure] = []
            if self.allowsDailySegments(plan: snapshot.plan),
               let analyticsURL = endpoint.analyticsURL,
               let weekly = snapshot.window(.weekly),
               let reset = weekly.resetsAt
            {
                do {
                    let segments = try await self.fetchDailySegments(
                        credentials: credentials,
                        weeklyReset: reset,
                        analyticsURL: analyticsURL,
                        allowedHost: endpoint.allowedHost)
                    if !segments.isEmpty {
                        var enriched = weekly
                        enriched.segments = segments
                        snapshot.replaceWindow(enriched)
                    }
                } catch let failure as AIUsageFailure {
                    partialFailures.append(failure)
                } catch {
                    partialFailures.append(AIUsageFailure(.network, "Codex 每日明细获取失败"))
                }
            }
            return AIUsageFetchResult(
                snapshot: snapshot,
                source: AIUsageSource(id: self.id, label: "OAuth", kind: .oauth, quality: .live),
                partialFailures: partialFailures)
        case 401, 403:
            throw AIUsageFailure(.unauthorized, "Codex 登录已失效，请运行 codex login")
        case 429:
            throw AIUsageFailure(.rateLimited, "Codex 用量接口暂时限流")
        default:
            throw AIUsageFailure(.httpStatus, "Codex 请求失败（HTTP \(response.statusCode)）")
        }
    }

    func shouldFallback(after failure: AIUsageFailure) -> Bool {
        switch failure.kind {
        case .schemaChanged, .security, .cancelled:
            false
        default:
            true
        }
    }

    private func allowsDailySegments(plan: AIUsagePlan?) -> Bool {
        guard let raw = plan?.rawValue?.lowercased() else { return false }
        return raw.contains("plus") || raw.contains("pro")
    }

    private func fetchDailySegments(
        credentials: CodexCredentials,
        weeklyReset: Date,
        analyticsURL: URL,
        allowedHost: String) async throws
        -> [AIUsageSegment]
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let start = weeklyReset.addingTimeInterval(-7 * 24 * 3600)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))
            ?? Date().addingTimeInterval(24 * 3600)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        guard var components = URLComponents(url: analyticsURL, resolvingAgainstBaseURL: false) else {
            throw AIUsageFailure(.schemaChanged, "Codex 每日明细端点无效")
        }
        components.queryItems = [
            URLQueryItem(name: "start_date", value: formatter.string(from: start)),
            URLQueryItem(name: "end_date", value: formatter.string(from: tomorrow)),
            URLQueryItem(name: "group_by", value: "day"),
        ]
        guard let url = components.url else {
            throw AIUsageFailure(.schemaChanged, "Codex 每日明细请求参数无效")
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        request.setValue(AIUsageVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await AIURLSessionHTTPTransport.shared.send(
            request,
            allowedHosts: [allowedHost])
        guard response.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any],
              let rows = json["data"] as? [[String: Any]]
        else {
            throw AIUsageFailure(.unavailable, "Codex 主用量可用，但每日明细暂不可用")
        }
        return rows.compactMap { row in
            guard let rawDate = row["date"] as? String,
                  let date = formatter.date(from: rawDate),
                  let totals = row["totals"] as? [String: Any],
                  let credits = AIJSON.number(totals["credits"]), credits > 0
            else { return nil }
            return AIUsageSegment(label: rawDate, date: date, value: credits)
        }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
    }
}

public enum CodexUsageParser {
    public static func parse(data: Data, now: Date = Date()) throws -> AIUsageSnapshot {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIUsageFailure(.schemaChanged, "Codex 返回了无法解析的用量数据")
        }
        return try self.parse(root: json, now: now)
    }

    static func parse(root: [String: Any], now: Date = Date()) throws -> AIUsageSnapshot {
        var windows: [AIUsageWindow] = []
        var extras: [AIUsageWindow] = []
        let primaryRaw: Any?
        let secondaryRaw: Any?
        if let rateLimit = root["rate_limit"] as? [String: Any] {
            primaryRaw = rateLimit["primary_window"]
            secondaryRaw = rateLimit["secondary_window"]
        } else if root["rate_limit"] != nil, !(root["rate_limit"] is NSNull) {
            throw AIUsageFailure(.schemaChanged, "Codex 的限额对象格式已变化")
        } else {
            primaryRaw = root["primary"]
            secondaryRaw = root["secondary"]
        }
        let primaryExplicitlyAbsent = primaryRaw == nil || primaryRaw is NSNull
        if !primaryExplicitlyAbsent, self.parseWindow(primaryRaw) == nil {
            throw AIUsageFailure(.schemaChanged, "Codex 的短周期窗口格式已变化")
        }
        if secondaryRaw != nil, !(secondaryRaw is NSNull), self.parseWindow(secondaryRaw) == nil {
            throw AIUsageFailure(.schemaChanged, "Codex 的周窗口格式已变化")
        }
        self.appendWindow(primaryRaw, windows: &windows, extras: &extras)
        self.appendWindow(secondaryRaw, windows: &windows, extras: &extras)

        if !windows.contains(where: { $0.id == .session }),
           windows.contains(where: { $0.id == .weekly })
        {
            windows.insert(AIUsageWindow(id: .session, value: .notEnforced), at: 0)
        }

        if let additional = root["additional_rate_limits"] as? [Any] {
            extras.append(contentsOf: self.additionalWindows(
                additional.compactMap { $0 as? [String: Any] }))
        }
        if let individual = self.individualLimit(root: root) {
            extras.append(individual)
        }

        guard windows.contains(where: \.hasData) || extras.contains(where: \.hasData) else {
            throw AIUsageFailure(.schemaChanged, "Codex 返回成功，但没有可识别的用量窗口")
        }
        return AIUsageSnapshot(
            providerID: .codex,
            windows: windows,
            extraWindows: extras,
            plan: self.plan(root["plan_type"] as? String),
            capturedAt: now)
    }

    private static func appendWindow(
        _ raw: Any?,
        windows: inout [AIUsageWindow],
        extras: inout [AIUsageWindow])
    {
        guard let parsed = self.parseWindow(raw) else { return }
        let window: AIUsageWindow
        switch Int(parsed.seconds.rounded()) {
        case 18_000:
            window = AIUsageWindow(
                id: .session,
                value: .measured(parsed.fraction),
                resetsAt: parsed.resetsAt)
            self.replace(window, in: &windows)
        case 604_800:
            window = AIUsageWindow(
                id: .weekly,
                value: .measured(parsed.fraction),
                resetsAt: parsed.resetsAt)
            self.replace(window, in: &windows)
        default:
            extras.append(AIUsageWindow(
                id: AIUsageWindowID(rawValue: "window-\(Int(parsed.seconds))"),
                title: self.durationTitle(seconds: parsed.seconds),
                value: .measured(parsed.fraction),
                resetsAt: parsed.resetsAt))
        }
    }

    private static func replace(_ window: AIUsageWindow, in windows: inout [AIUsageWindow]) {
        if let index = windows.firstIndex(where: { $0.id == window.id }) {
            windows[index] = window
        } else {
            windows.append(window)
        }
    }

    private static func durationTitle(seconds: Double) -> String {
        if seconds >= 86_400, seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
            return "\(Int(seconds / 86_400)) 天窗口"
        }
        if seconds >= 3_600, seconds.truncatingRemainder(dividingBy: 3_600) == 0 {
            return "\(Int(seconds / 3_600)) 小时窗口"
        }
        return "\(max(Int((seconds / 60).rounded()), 1)) 分钟窗口"
    }

    private static func parseWindow(_ raw: Any?) -> (seconds: Double, fraction: Double, resetsAt: Date?)? {
        guard let window = raw as? [String: Any],
              let fraction = AIJSON.fraction(percent: window["used_percent"] ?? window["utilization"])
        else { return nil }
        let seconds = AIJSON.number(window["limit_window_seconds"])
            ?? AIJSON.number(window["window_minutes"]).map { $0 * 60 }
        guard let seconds, seconds > 0 else { return nil }
        return (seconds, fraction, AIJSON.date(window["reset_at"] ?? window["resets_at"]))
    }

    /// Codex 的额外限额通常按模型给出。普通模型仅展示主窗口，主窗口无效时才回退次窗口；
    /// Spark 同时保留短周期与周周期，并使用固定 ID，避免服务端文案变化导致 UI 身份漂移。
    private static func additionalWindows(_ entries: [[String: Any]]) -> [AIUsageWindow] {
        var windows: [AIUsageWindow] = []
        var usedIDs = Set<AIUsageWindowID>()

        for entry in entries {
            guard let rateLimit = entry["rate_limit"] as? [String: Any] else { continue }
            let limitName = self.nonEmptyString(entry["limit_name"])
            let meteredFeature = self.nonEmptyString(entry["metered_feature"])
            let names = [limitName, meteredFeature].compactMap { $0?.lowercased() }

            if names.contains(where: { $0.contains("spark") }) {
                let candidates: [(Any?, SparkWindowKind)] = [
                    (rateLimit["primary_window"], .session),
                    (rateLimit["secondary_window"], .weekly),
                ]
                for (raw, fallbackKind) in candidates {
                    guard let parsed = self.parseWindow(raw) else { continue }
                    let kind = SparkWindowKind(seconds: parsed.seconds, fallback: fallbackKind)
                    guard usedIDs.insert(kind.id).inserted else { continue }
                    windows.append(AIUsageWindow(
                        id: kind.id,
                        title: kind.title,
                        value: .measured(parsed.fraction),
                        resetsAt: parsed.resetsAt))
                }
                continue
            }

            guard let parsed = self.parseWindow(rateLimit["primary_window"])
                ?? self.parseWindow(rateLimit["secondary_window"]),
                let identity = meteredFeature ?? limitName
            else { continue }
            let slug = self.slug(identity)
            guard !slug.isEmpty else { continue }
            let id = AIUsageWindowID(rawValue: "codex-\(slug)")
            guard usedIDs.insert(id).inserted else { continue }
            windows.append(AIUsageWindow(
                id: id,
                title: limitName ?? meteredFeature ?? "Codex extra limit",
                value: .measured(parsed.fraction),
                resetsAt: parsed.resetsAt))
        }
        return windows
    }

    private static func individualLimit(root: [String: Any]) -> AIUsageWindow? {
        let rateLimit = root["rate_limit"] as? [String: Any]
        let raw = (rateLimit?["individual_limit"] ?? rateLimit?["individualLimit"]
            ?? root["individual_limit"] ?? root["individualLimit"]) as? [String: Any]
        guard let raw else { return nil }

        let fraction: Double?
        if let used = AIJSON.number(raw["used"]), used.isFinite, used >= 0,
           let limit = AIJSON.number(raw["limit"]), limit.isFinite, limit > 0
        {
            fraction = min(max(used / limit, 0), 1)
        } else if let remaining = AIJSON.number(raw["remaining_percent"] ?? raw["remainingPercent"]),
                  remaining.isFinite
        {
            fraction = min(max(1 - remaining / 100, 0), 1)
        } else {
            fraction = nil
        }
        guard let fraction else { return nil }
        return AIUsageWindow(
            id: AIUsageWindowID(rawValue: "codex-individual-limit"),
            title: "月度额度",
            value: .measured(fraction),
            resetsAt: AIJSON.date(raw["resets_at"] ?? raw["resetsAt"] ?? raw["reset_at"] ?? raw["resetAt"]))
    }

    private enum SparkWindowKind {
        case session
        case weekly

        static let sessionID = AIUsageWindowID(rawValue: "codex-spark")
        static let weeklyID = AIUsageWindowID(rawValue: "codex-spark-weekly")

        init(seconds: Double, fallback: Self) {
            if seconds <= 6 * 3600 {
                self = .session
            } else if seconds >= 6 * 24 * 3600 {
                self = .weekly
            } else {
                self = fallback
            }
        }

        var id: AIUsageWindowID {
            switch self {
            case .session: Self.sessionID
            case .weekly: Self.weeklyID
            }
        }

        var title: String {
            switch self {
            case .session: "Codex Spark 5 小时"
            case .weekly: "Codex Spark 7 天"
            }
        }
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = raw as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func slug(_ value: String) -> String {
        var result = ""
        var lastWasDash = false
        for scalar in value.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result.append("-")
                lastWasDash = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func plan(_ raw: String?) -> AIUsagePlan? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        let display: String
        if lower.contains("enterprise") { display = "Enterprise" }
        else if lower.contains("team") { display = "Team" }
        else if lower.contains("plus") { display = "Plus" }
        else if lower.contains("pro") { display = "Pro" }
        else { display = raw.prefix(1).uppercased() + raw.dropFirst() }
        return AIUsagePlan(rawValue: raw, displayName: display)
    }
}

private struct CodexRolloutUsageStrategy: AIUsageFetchStrategy {
    let id = "codex.rollout"
    let kind = AIUsageFetchKind.local

    private static let maximumFiles = 128
    private static let maximumBytesPerFile = 1_048_576
    private static let maximumTotalBytes = 48 * 1_048_576

    private struct RolloutFile {
        let url: URL
        let modifiedAt: Date
        let size: Int
    }

    func availability(context _: AIUsageFetchContext) async -> AIStrategyAvailability {
        let roots = self.roots()
        return roots.contains { FileManager.default.fileExists(atPath: $0.path) }
            ? .available
            : .unavailable(AIUsageFailure(.localData, "未找到 Codex 本地会话"))
    }

    func fetch(context _: AIUsageFetchContext) async throws -> AIUsageFetchResult {
        let now = Date()
        var remainingBytes = Self.maximumTotalBytes
        var latestSnapshot: AIUsageSnapshot?
        for file in self.recentRolloutFiles(limit: Self.maximumFiles) where remainingBytes > 0 {
            let byteLimit = min(Self.maximumBytesPerFile, file.size, remainingBytes)
            guard byteLimit > 0 else { continue }
            remainingBytes -= byteLimit
            guard let snapshot = self.latestValidSnapshot(
                in: file,
                maximumBytes: byteLimit,
                now: now)
            else { continue }
            if snapshot.capturedAt > (latestSnapshot?.capturedAt ?? .distantPast) {
                latestSnapshot = snapshot
            }
        }
        guard var snapshot = latestSnapshot else {
            throw AIUsageFailure(.localData, "Codex 本地会话中没有可识别的用量快照")
        }
        if snapshot.plan == nil {
            snapshot.plan = CodexUsageParser.plan(CodexCredentialStore.localPlan())
        }
        return AIUsageFetchResult(
            snapshot: snapshot,
            source: AIUsageSource(
                id: self.id,
                label: "本地会话快照",
                kind: .local,
                quality: .cached))
    }

    private func roots() -> [URL] {
        let home = AIKnownPaths.codexHome()
        return [
            home.appendingPathComponent("sessions", isDirectory: true),
            home.appendingPathComponent("archived_sessions", isDirectory: true),
        ]
    }

    private func recentRolloutFiles(limit: Int) -> [RolloutFile] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        var candidates: [RolloutFile] = []
        for root in self.roots() {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in enumerator
            where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-")
            {
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modifiedAt = values.contentModificationDate,
                      let size = values.fileSize,
                      size > 0
                else { continue }
                candidates.append(RolloutFile(
                    url: url.standardizedFileURL,
                    modifiedAt: modifiedAt,
                    size: size))
                if candidates.count > limit * 4 {
                    candidates.sort(by: self.isNewerFile)
                    candidates.removeSubrange(limit * 2..<candidates.count)
                }
            }
        }
        return Array(candidates.sorted(by: self.isNewerFile).prefix(limit))
    }

    private func isNewerFile(_ lhs: RolloutFile, _ rhs: RolloutFile) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        return lhs.url.path < rhs.url.path
    }

    /// 逐行解码尾部，正在追加的半个 UTF-8 标量或 malformed 新事件不会遮蔽更早的有效快照。
    private func latestValidSnapshot(
        in file: RolloutFile,
        maximumBytes: Int,
        now: Date) -> AIUsageSnapshot?
    {
        guard let lines = self.reverseLines(in: file.url, maximumBytes: maximumBytes) else { return nil }
        var latest: AIUsageSnapshot?
        for line in lines {
            guard line.range(of: Data("rate_limits".utf8)) != nil,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let limits = self.rateLimits(in: object)
            else { continue }
            let rawDate = self.eventTimestamp(in: object) ?? file.modifiedAt
            let capturedAt = rawDate > now.addingTimeInterval(300)
                ? min(file.modifiedAt, now)
                : rawDate
            guard let snapshot = try? CodexUsageParser.parse(root: limits, now: capturedAt)
            else { continue }
            if snapshot.capturedAt > (latest?.capturedAt ?? .distantPast) {
                latest = snapshot
            }
        }
        return latest
    }

    /// 读取固定的初始文件尾部；若截断点前一字节是 LF，说明首行完整，不应误删。
    private func reverseLines(in url: URL, maximumBytes: Int) -> [Data]? {
        guard maximumBytes > 0, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            let byteCount = min(UInt64(maximumBytes), size)
            let start = size - byteCount
            var startsAtLineBoundary = start == 0
            if start > 0 {
                try handle.seek(toOffset: start - 1)
                startsAtLineBoundary = try handle.read(upToCount: 1)?.first == 0x0A
            }
            try handle.seek(toOffset: start)
            var tail = try handle.read(upToCount: Int(byteCount)) ?? Data()
            if !startsAtLineBoundary {
                guard let newline = tail.firstIndex(of: 0x0A) else { return [] }
                tail.removeSubrange(tail.startIndex...newline)
            }
            return Array(tail).split(separator: 0x0A, omittingEmptySubsequences: true)
                .reversed()
                .map { Data($0) }
        } catch {
            return nil
        }
    }

    private func eventTimestamp(in object: [String: Any]) -> Date? {
        func timestamp(_ dictionary: [String: Any]) -> Date? {
            for key in ["timestamp", "created_at", "createdAt"] {
                if let date = AIJSON.date(dictionary[key]) { return date }
            }
            return nil
        }
        return timestamp(object)
            ?? (object["payload"] as? [String: Any]).flatMap(timestamp)
            ?? (object["info"] as? [String: Any]).flatMap(timestamp)
    }

    /// 只接受 Codex token_count 事件的已知路径，避免用户消息中的同名 JSON 污染缓存。
    private func rateLimits(in object: [String: Any]) -> [String: Any]? {
        if let payload = object["payload"] as? [String: Any] {
            if object["type"] as? String == "event_msg",
               let payloadType = payload["type"] as? String,
               payloadType != "token_count"
            {
                return nil
            }
            if let limits = payload["rate_limits"] as? [String: Any] { return limits }
            if let info = payload["info"] as? [String: Any],
               let limits = info["rate_limits"] as? [String: Any]
            {
                return limits
            }
        }
        if let limits = object["rate_limits"] as? [String: Any] { return limits }
        if let info = object["info"] as? [String: Any],
           let limits = info["rate_limits"] as? [String: Any]
        {
            return limits
        }
        return nil
    }
}
