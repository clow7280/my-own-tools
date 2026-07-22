import Foundation
import SQLite3

enum OpenCodeAIProvider {
    static let descriptor = AIProviderDescriptor(
        id: .openCode,
        displayName: "OpenCode",
        refreshPolicy: AIProviderRefreshPolicy(minimumAutomaticInterval: 180),
        strategies: [OpenCodeLocalUsageStrategy(), OpenCodeWebUsageStrategy()])
}

private struct OpenCodeLocalUsageStrategy: AIUsageFetchStrategy {
    let id = "opencode-go.local"
    let kind = AIUsageFetchKind.local

    func availability(context _: AIUsageFetchContext) async -> AIStrategyAvailability {
        FileManager.default.fileExists(atPath: OpenCodeLocalUsageReader.defaultDatabaseURL.path)
            ? .available
            : .unavailable(AIUsageFailure(.localData, "未找到 OpenCode 本地用量数据库"))
    }

    func fetch(context _: AIUsageFetchContext) async throws -> AIUsageFetchResult {
        let snapshot = try OpenCodeLocalUsageReader().fetch()
        return AIUsageFetchResult(
            snapshot: snapshot,
            source: AIUsageSource(
                id: self.id,
                label: "本地估算",
                kind: .local,
                quality: .estimated))
    }

    func shouldFallback(after failure: AIUsageFailure) -> Bool {
        failure.kind != .cancelled && failure.kind != .security
    }
}

private struct OpenCodeWebUsageStrategy: AIUsageFetchStrategy {
    let id = "opencode-go.web"
    let kind = AIUsageFetchKind.web

    func fetch(context: AIUsageFetchContext) async throws -> AIUsageFetchResult {
        var attempted = Set<String>()
        var lastRejection: AIUsageFailure?
        if let cached = OpenCodeBrowserCookieReader.validatedCandidate() {
            do {
                return try await self.fetch(candidate: cached)
            } catch let failure as AIUsageFailure
                where failure.kind == .unauthorized || failure.kind == .candidateRejected
            {
                OpenCodeBrowserCookieReader.invalidateValidated(cached)
                attempted.insert(cached.fingerprint)
                lastRejection = failure
            }
        }

        var browserIndex = 0
        var candidateCount = 0
        while candidateCount < 12,
              let batch = OpenCodeBrowserCookieReader.candidateBatch(
                  startingAt: browserIndex,
                  excluding: attempted,
                  allowsUserInteraction: context.allowsCredentialPrompt)
        {
            browserIndex = batch.nextBrowserIndex
            for candidate in batch.candidates.prefix(12 - candidateCount) {
                candidateCount += 1
                attempted.insert(candidate.fingerprint)
                do {
                    return try await self.fetch(candidate: candidate)
                } catch let failure as AIUsageFailure
                    where failure.kind == .unauthorized || failure.kind == .candidateRejected
                {
                    lastRejection = failure
                    continue
                }
            }
        }
        if candidateCount == 0, lastRejection == nil {
            let message = context.allowsCredentialPrompt
                ? "未找到浏览器中的 OpenCode 登录"
                : "未找到可无交互读取的 OpenCode 登录，请手动刷新授权"
            throw AIUsageFailure(.credentialMissing, message)
        }
        throw lastRejection ?? AIUsageFailure(.credentialMissing, "未找到可用的 OpenCode 网页登录")
    }

    private func fetch(candidate: OpenCodeCookieCandidate) async throws -> AIUsageFetchResult {
        let snapshot = try await OpenCodeWebClient.fetch(cookieHeader: candidate.header)
        OpenCodeBrowserCookieReader.markValidated(candidate)
        return AIUsageFetchResult(
            snapshot: snapshot,
            source: AIUsageSource(id: self.id, label: "网页", kind: .web, quality: .live))
    }
}

public struct OpenCodeLocalUsageReader {
    static let defaultDatabaseURL = AIKnownPaths.homeDirectory
        .appendingPathComponent(".local", isDirectory: true)
        .appendingPathComponent("share", isDirectory: true)
        .appendingPathComponent("opencode", isDirectory: true)
        .appendingPathComponent("opencode.db", isDirectory: false)

    private static let fiveHours: TimeInterval = 5 * 3600
    private static let week: TimeInterval = 7 * 24 * 3600
    /// OpenCode Go 当前公开套餐的美元额度；本地结果必须标记 estimated。
    private static let limits = (session: 12.0, weekly: 30.0, monthly: 60.0)
    private let databaseURL: URL

    private struct Row {
        let createdMilliseconds: Int64
        let cost: Double
    }

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL ?? Self.defaultDatabaseURL
    }

    public func fetch(now: Date = Date()) throws -> AIUsageSnapshot {
        let rows = try self.readRows(now: now)
        guard !rows.isEmpty else {
            throw AIUsageFailure(.localData, "OpenCode 本地数据库中没有 Go 用量记录")
        }

        let nowMilliseconds = Int64(now.timeIntervalSince1970 * 1000)
        let sessionStart = nowMilliseconds - Int64(Self.fiveHours * 1000)
        let weekStart = Int64(Self.startOfUTCWeek(now).timeIntervalSince1970 * 1000)
        let weekEnd = weekStart + Int64(Self.week * 1000)
        let month = Self.monthBounds(now: now, anchorMilliseconds: rows.map(\.createdMilliseconds).min())

        var sessionCost = 0.0
        var weeklyCost = 0.0
        var monthlyCost = 0.0
        var oldestSession: Int64?
        for row in rows {
            if row.createdMilliseconds >= sessionStart, row.createdMilliseconds <= nowMilliseconds {
                sessionCost += row.cost
                if oldestSession.map({ row.createdMilliseconds < $0 }) ?? true {
                    oldestSession = row.createdMilliseconds
                }
            }
            if row.createdMilliseconds >= weekStart, row.createdMilliseconds < weekEnd {
                weeklyCost += row.cost
            }
            if row.createdMilliseconds >= month.start, row.createdMilliseconds < month.end {
                monthlyCost += row.cost
            }
        }

        let sessionReset = oldestSession.map {
            Date(timeIntervalSince1970: TimeInterval($0) / 1000 + Self.fiveHours)
        }
        let windows = [
            AIUsageWindow(
                id: .session,
                value: .measured(Self.fraction(used: sessionCost, limit: Self.limits.session)),
                resetsAt: sessionReset),
            AIUsageWindow(
                id: .weekly,
                value: .measured(Self.fraction(used: weeklyCost, limit: Self.limits.weekly)),
                resetsAt: Date(timeIntervalSince1970: TimeInterval(weekEnd) / 1000)),
            AIUsageWindow(
                id: .monthly,
                value: .measured(Self.fraction(used: monthlyCost, limit: Self.limits.monthly)),
                resetsAt: Date(timeIntervalSince1970: TimeInterval(month.end) / 1000)),
        ]
        return AIUsageSnapshot(
            providerID: .openCode,
            windows: windows,
            plan: AIUsagePlan(rawValue: "opencode-go", displayName: "Go"),
            capturedAt: now)
    }

    private func readRows(now: Date) throws -> [Row] {
        var database: OpaquePointer?
        guard sqlite3_open_v2(
            self.databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK,
            let database
        else {
            sqlite3_close(database)
            throw AIUsageFailure(.localData, "无法只读打开 OpenCode 本地数据库")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        let sql = self.hasPartTable(database) ? Self.messageAndPartSQL : Self.messageSQL
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw AIUsageFailure(.localData, "OpenCode 本地数据库结构暂不支持")
        }
        defer { sqlite3_finalize(statement) }
        // 当前窗口最多跨前一个月；额外保留一条全历史 anchor 行来计算账期，而不把整库装入内存。
        let cutoff = Int64(now.addingTimeInterval(-40 * 24 * 3600).timeIntervalSince1970 * 1000)
        sqlite3_bind_int64(statement, 1, cutoff)

        var rows: [Row] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else {
                throw AIUsageFailure(.localData, "读取 OpenCode 本地用量失败")
            }
            let created = sqlite3_column_int64(statement, 0)
            let cost = sqlite3_column_double(statement, 1)
            guard created > 0, cost >= 0, cost.isFinite else { continue }
            rows.append(Row(createdMilliseconds: created, cost: cost))
        }
        return rows
    }

    private func hasPartTable(_ database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type='table' AND name='part' LIMIT 1",
            -1,
            &statement,
            nil) == SQLITE_OK,
            let statement
        else { return false }
        defer { sqlite3_finalize(statement) }
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private static let messageSQL = """
        WITH usage_rows AS (
          SELECT
            CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
            CAST(json_extract(data, '$.cost') AS REAL) AS cost
          FROM message
          WHERE json_valid(data)
            AND json_extract(data, '$.providerID') = 'opencode-go'
            AND json_extract(data, '$.role') = 'assistant'
            AND json_type(data, '$.cost') IN ('integer', 'real')
        )
        SELECT createdMs, cost FROM usage_rows WHERE createdMs >= ?1
        UNION ALL
        SELECT MIN(createdMs), 0 FROM usage_rows HAVING MIN(createdMs) < ?1
        """

    private static let messageAndPartSQL = """
        WITH provider_messages AS (
          SELECT
            id AS messageID,
            CAST(COALESCE(json_extract(data, '$.time.created'), time_created) AS INTEGER) AS createdMs,
            CAST(json_extract(data, '$.cost') AS REAL) AS cost,
            json_type(data, '$.cost') IN ('integer', 'real') AS hasCost
          FROM message
          WHERE json_valid(data)
            AND json_extract(data, '$.providerID') = 'opencode-go'
            AND json_extract(data, '$.role') = 'assistant'
        )
        , usage_rows AS (
          SELECT
            CAST(COALESCE(json_extract(p.data, '$.time.created'), p.time_created, m.createdMs) AS INTEGER)
              AS createdMs,
            CAST(json_extract(p.data, '$.cost') AS REAL) AS cost
          FROM part p
          JOIN provider_messages m ON m.messageID = p.message_id
          WHERE json_valid(p.data)
            AND json_extract(p.data, '$.type') = 'step-finish'
            AND json_type(p.data, '$.cost') IN ('integer', 'real')
          UNION ALL
          SELECT createdMs, cost
          FROM provider_messages m
          WHERE hasCost
            AND NOT EXISTS (
              SELECT 1 FROM part p
              WHERE p.message_id = m.messageID
                AND json_valid(p.data)
                AND json_extract(p.data, '$.type') = 'step-finish'
                AND json_type(p.data, '$.cost') IN ('integer', 'real')
            )
        )
        SELECT createdMs, cost FROM usage_rows WHERE createdMs >= ?1
        UNION ALL
        SELECT MIN(createdMs), 0 FROM usage_rows HAVING MIN(createdMs) < ?1
        """

    private static func fraction(used: Double, limit: Double) -> Double {
        guard used.isFinite, limit > 0 else { return 0 }
        return min(max(used / limit, 0), 1)
    }

    private static func startOfUTCWeek(_ now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
    }

    private static func monthBounds(now: Date, anchorMilliseconds: Int64?) -> (start: Int64, end: Int64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        guard let anchorMilliseconds else {
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
            let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
            return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
        }

        let anchor = Date(timeIntervalSince1970: TimeInterval(anchorMilliseconds) / 1000)
        let anchorParts = calendar.dateComponents([.day, .hour, .minute, .second], from: anchor)
        var monthParts = calendar.dateComponents([.year, .month], from: now)
        var start = self.anchoredMonth(calendar: calendar, month: monthParts, anchor: anchorParts)
        if start > now, let previous = calendar.date(byAdding: .month, value: -1, to: start) {
            monthParts = calendar.dateComponents([.year, .month], from: previous)
            start = self.anchoredMonth(calendar: calendar, month: monthParts, anchor: anchorParts)
        }
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        let nextParts = calendar.dateComponents([.year, .month], from: nextMonth)
        let end = self.anchoredMonth(calendar: calendar, month: nextParts, anchor: anchorParts)
        return (Int64(start.timeIntervalSince1970 * 1000), Int64(end.timeIntervalSince1970 * 1000))
    }

    private static func anchoredMonth(
        calendar: Calendar,
        month: DateComponents,
        anchor: DateComponents) -> Date
    {
        var components = month
        components.timeZone = calendar.timeZone
        components.day = anchor.day
        components.hour = anchor.hour
        components.minute = anchor.minute
        components.second = anchor.second
        if let date = calendar.date(from: components), calendar.component(.month, from: date) == month.month {
            return date
        }
        let monthDate = calendar.date(from: month) ?? Date()
        components.day = calendar.range(of: .day, in: .month, for: monthDate)?.count
        return calendar.date(from: components) ?? monthDate
    }
}

private enum OpenCodeWebClient {
    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) "
        + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 MyOwnTools/0.2"

    static func fetch(cookieHeader: String, now: Date = Date()) async throws -> AIUsageSnapshot {
        guard cookieHeader.aiSafeHeaderValue != nil else {
            throw AIUsageFailure(.security, "OpenCode Cookie 含非法字符")
        }
        let workspaceIDs = try await self.fetchWorkspaceIDs(cookieHeader: cookieHeader)
        guard !workspaceIDs.isEmpty else {
            throw AIUsageFailure(.candidateRejected, "OpenCode 登录中未找到工作区")
        }

        var schemaFailure: AIUsageFailure?
        var rejectedWorkspace = false
        for workspaceID in workspaceIDs.prefix(8) {
            do {
                return try await self.fetchGoPage(
                    cookieHeader: cookieHeader,
                    workspaceID: workspaceID,
                    now: now)
            } catch let failure as AIUsageFailure where failure.kind == .schemaChanged
                || failure.kind == .candidateRejected
            {
                if failure.kind == .schemaChanged { schemaFailure = failure }
                else { rejectedWorkspace = true }
            }
        }
        if let schemaFailure { throw schemaFailure }
        if rejectedWorkspace {
            throw AIUsageFailure(.candidateRejected, "OpenCode 工作区没有可用的 Go 用量")
        }
        throw AIUsageFailure(.candidateRejected, "OpenCode 工作区没有可识别的 Go 用量")
    }

    /// SolidStart 偶尔以 200 返回空 GET 结果；缺少工作区时仍需用 POST 重试。
    private static func fetchWorkspaceIDs(cookieHeader: String) async throws -> [String] {
        let text = try await self.serverFunctionRequest(
            id: self.workspacesServerID,
            arguments: nil,
            method: "GET",
            cookieHeader: cookieHeader,
            referer: self.baseURL)

        let ids = self.workspaceIDs(in: text)
        guard ids.isEmpty else { return ids }
        let fallback = try await self.serverFunctionRequest(
            id: self.workspacesServerID,
            arguments: [],
            method: "POST",
            cookieHeader: cookieHeader,
            referer: self.baseURL)
        return try self.workspaceIDsOrFailure(in: fallback)
    }

    private static func fetchGoPage(
        cookieHeader: String,
        workspaceID: String,
        now: Date) async throws -> AIUsageSnapshot
    {
        guard workspaceID.hasPrefix("wrk_"),
              let url = URL(string: "https://opencode.ai/workspace/\(workspaceID)/go")
        else {
            throw AIUsageFailure(.schemaChanged, "OpenCode 工作区标识无效")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let response = try await AIURLSessionHTTPTransport.shared.send(request, allowedHosts: ["opencode.ai"])
        guard let text = String(data: response.data, encoding: .utf8) else {
            throw AIUsageFailure(.schemaChanged, "OpenCode 返回了非 UTF-8 数据")
        }
        if response.statusCode == 401 || response.statusCode == 403 || (300...399).contains(response.statusCode)
            || self.looksSignedOut(text)
        {
            throw AIUsageFailure(.unauthorized, "OpenCode 网页登录已过期")
        }
        if response.statusCode == 404 {
            throw AIUsageFailure(.candidateRejected, "OpenCode 工作区没有 Go 用量页面")
        }
        if response.statusCode == 429 {
            throw AIUsageFailure(.rateLimited, "OpenCode 用量接口暂时限流")
        }
        guard response.statusCode == 200 else {
            throw AIUsageFailure(.httpStatus, "OpenCode 请求失败（HTTP \(response.statusCode)）")
        }
        return try OpenCodeUsageParser.parse(text: text, now: now)
    }

    private static func serverFunctionRequest(
        id: String,
        arguments: [Any]?,
        method: String,
        cookieHeader: String,
        referer: URL) async throws -> String
    {
        var components = URLComponents(url: self.serverURL, resolvingAgainstBaseURL: false)!
        if method == "GET" {
            var query = [URLQueryItem(name: "id", value: id)]
            if let arguments, !arguments.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: arguments),
               let encoded = String(data: data, encoding: .utf8)
            {
                query.append(URLQueryItem(name: "args", value: encoded))
            }
            components.queryItems = query
        }
        var request = URLRequest(
            url: components.url ?? self.serverURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 15)
        request.httpMethod = method
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(id, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if method == "POST" {
            request.httpBody = try JSONSerialization.data(withJSONObject: arguments ?? [])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await AIURLSessionHTTPTransport.shared.send(request, allowedHosts: ["opencode.ai"])
        guard let text = String(data: response.data, encoding: .utf8) else {
            throw AIUsageFailure(.schemaChanged, "OpenCode 返回了非 UTF-8 数据")
        }
        if response.statusCode == 401 || response.statusCode == 403 || (300...399).contains(response.statusCode)
            || self.looksSignedOut(text)
        {
            throw AIUsageFailure(.unauthorized, "OpenCode 网页登录已过期")
        }
        if response.statusCode == 429 {
            throw AIUsageFailure(.rateLimited, "OpenCode 用量接口暂时限流")
        }
        guard response.statusCode == 200 else {
            throw AIUsageFailure(.httpStatus, "OpenCode 请求失败（HTTP \(response.statusCode)）")
        }
        return text
    }

    private static func workspaceIDs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"wrk_[A-Za-z0-9_-]+"#) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            let id = String(text[swiftRange])
            return seen.insert(id).inserted ? id : nil
        }
    }

    private static func workspaceIDsOrFailure(in text: String) throws -> [String] {
        let ids = self.workspaceIDs(in: text)
        if !ids.isEmpty { return ids }
        if self.isExplicitEmptyWorkspacePayload(text) { return [] }
        throw AIUsageFailure(.schemaChanged, "OpenCode 工作区列表格式已变化")
    }

    private static func isExplicitEmptyWorkspacePayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(
            of: #"\$R\[0\]\s*=\s*\[\s*\]"#,
            options: .regularExpression) != nil
        {
            return true
        }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return false }
        return self.isExplicitEmptyWorkspaceValue(object, allowArrayWrapper: true)
    }

    private static func isExplicitEmptyWorkspaceValue(_ value: Any, allowArrayWrapper: Bool) -> Bool {
        if let array = value as? [Any] {
            if array.isEmpty { return true }
            return allowArrayWrapper && array.count == 1
                && self.isExplicitEmptyWorkspaceValue(array[0], allowArrayWrapper: false)
        }
        guard let dictionary = value as? [String: Any] else { return false }
        if let workspaces = dictionary["workspaces"] as? [Any], workspaces.isEmpty { return true }
        for key in ["data", "result"] {
            if let child = dictionary[key],
               self.isExplicitEmptyWorkspaceValue(child, allowArrayWrapper: true)
            {
                return true
            }
        }
        return false
    }

    private static func looksSignedOut(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("login")
            || lower.contains("sign in")
            || lower.contains("auth/authorize")
            || lower.contains("not associated with an account")
            || lower.contains("actor of type \"public\"")
    }
}

public enum OpenCodeUsageParser {
    private static let percentKeys = [
        "usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent", "used_percent",
        "utilization", "utilizationPercent", "utilization_percent",
    ]
    private static let usedKeys = ["used", "usage", "consumed"]
    private static let limitKeys = ["limit", "total", "capacity"]
    private static let resetSecondsKeys = [
        "resetInSec", "resetInSeconds", "resetSeconds", "reset_sec", "reset_in_sec", "resetsInSec",
        "resetsInSeconds", "resetAfterSeconds", "resetIn", "resetSec",
    ]
    private static let resetDateKeys = [
        "resetsAt", "resetAt", "resets_at", "reset_at", "nextReset", "next_reset", "renewAt", "renew_at",
    ]

    public static func parse(text: String, now: Date = Date()) throws -> AIUsageSnapshot {
        var windows: [AIUsageWindow] = []
        if let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data)
        {
            self.collectWindows(in: object, now: now, windows: &windows, depth: 0)
        }
        if windows.isEmpty {
            self.appendTextWindow(
                names: ["rollingUsage", "rolling_usage"],
                id: .session,
                text: text,
                now: now,
                windows: &windows)
            self.appendTextWindow(
                names: ["weeklyUsage", "weekly_usage"],
                id: .weekly,
                text: text,
                now: now,
                windows: &windows)
            self.appendTextWindow(
                names: ["monthlyUsage", "monthly_usage"],
                id: .monthly,
                text: text,
                now: now,
                windows: &windows)
        }
        guard windows.contains(where: { $0.id == .session && $0.hasData }) else {
            throw AIUsageFailure(.schemaChanged, "OpenCode 返回了未知用量格式")
        }
        return AIUsageSnapshot(
            providerID: .openCode,
            windows: windows,
            plan: AIUsagePlan(rawValue: "opencode-go", displayName: "Go"),
            capturedAt: now)
    }

    private static func collectWindows(
        in object: Any,
        now: Date,
        windows: inout [AIUsageWindow],
        depth: Int)
    {
        guard depth <= 8 else { return }
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                let id: AIUsageWindowID? = switch key {
                case "rolling", "rollingUsage", "rolling_usage", "rollingWindow", "rolling_window": .session
                case "weekly", "weeklyUsage", "weekly_usage", "weeklyWindow", "weekly_window": .weekly
                case "monthly", "monthlyUsage", "monthly_usage", "monthlyWindow", "monthly_window": .monthly
                default: nil
                }
                if let id, let window = self.window(id: id, raw: value, now: now) {
                    self.replace(window, in: &windows)
                }
                self.collectWindows(in: value, now: now, windows: &windows, depth: depth + 1)
            }
        } else if let array = object as? [Any] {
            for value in array {
                self.collectWindows(in: value, now: now, windows: &windows, depth: depth + 1)
            }
        }
    }

    private static func window(id: AIUsageWindowID, raw: Any, now: Date) -> AIUsageWindow? {
        guard let dictionary = raw as? [String: Any] else { return nil }
        let values: [String: Any]
        if self.usageFraction(in: dictionary) != nil {
            values = dictionary
        } else if let nested = dictionary["window"] as? [String: Any] {
            values = nested
        } else {
            return nil
        }
        guard let fraction = self.usageFraction(in: values) else { return nil }
        let seconds = self.resetSecondsKeys.lazy.compactMap { AIJSON.number(values[$0]) }.first
        let date = seconds.map { now.addingTimeInterval($0) }
            ?? self.resetDateKeys.lazy.compactMap { AIJSON.date(values[$0]) }.first
        return AIUsageWindow(id: id, value: .measured(fraction), resetsAt: date)
    }

    private static func appendTextWindow(
        names: [String],
        id: AIUsageWindowID,
        text: String,
        now: Date,
        windows: inout [AIUsageWindow])
    {
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            let pattern = #"(?:\\?[\"'])?"# + escaped
                + #"(?:\\?[\"'])?\s*:\s*(?:\$R\[[0-9]{1,8}\]\s*=\s*)?\{([^{}]{0,1600})\}"#
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard let body = Range(match.range(at: 1), in: text) else { continue }
                let segment = String(text[body])
                guard let fraction = self.textUsageFraction(in: segment) else { continue }
                let resetSeconds = self.textNumber(keys: self.resetSecondsKeys, in: segment)
                self.replace(AIUsageWindow(
                    id: id,
                    value: .measured(fraction),
                    resetsAt: resetSeconds.map { now.addingTimeInterval($0) }), in: &windows)
                return
            }
        }
    }

    private static func usageFraction(in dictionary: [String: Any]) -> Double? {
        for key in self.percentKeys {
            guard let value = AIJSON.number(dictionary[key]), value.isFinite else { continue }
            if (0...1).contains(value) { return value }
            return min(max(value / 100, 0), 1)
        }
        let used = self.usedKeys.lazy.compactMap { AIJSON.number(dictionary[$0]) }.first
        let limit = self.limitKeys.lazy.compactMap { AIJSON.number(dictionary[$0]) }.first
        if let used, let limit, used.isFinite, limit.isFinite, limit > 0 {
            return min(max(used / limit, 0), 1)
        }
        if let usage = AIJSON.number(dictionary["usage"]), usage.isFinite {
            if (0...1).contains(usage) { return usage }
            return min(max(usage / 100, 0), 1)
        }
        return nil
    }

    private static func textUsageFraction(in text: String) -> Double? {
        for key in self.percentKeys {
            guard let value = self.textNumber(keys: [key], in: text), value.isFinite else { continue }
            if key == "utilization", (0...1).contains(value) { return value }
            return min(max(value / 100, 0), 1)
        }
        let used = self.textNumber(keys: self.usedKeys, in: text)
        let limit = self.textNumber(keys: self.limitKeys, in: text)
        if let used, let limit, used.isFinite, limit.isFinite, limit > 0 {
            return min(max(used / limit, 0), 1)
        }
        if let usage = self.textNumber(keys: ["usage"], in: text), usage.isFinite {
            if (0...1).contains(usage) { return usage }
            return min(max(usage / 100, 0), 1)
        }
        return nil
    }

    private static func textNumber(keys: [String], in text: String) -> Double? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"(?:\\?[\"'])?"# + escaped
                + #"(?:\\?[\"'])?\s*:\s*[\"']?(-?[0-9]+(?:\.[0-9]+)?)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                      in: text,
                      range: NSRange(text.startIndex..<text.endIndex, in: text)),
                  let range = Range(match.range(at: 1), in: text)
            else { continue }
            if let value = Double(text[range]) { return value }
        }
        return nil
    }

    private static func replace(_ window: AIUsageWindow, in windows: inout [AIUsageWindow]) {
        if let index = windows.firstIndex(where: { $0.id == window.id }) {
            windows[index] = window
        } else {
            windows.append(window)
        }
    }
}
