import AIUsageCore
import Darwin
import Foundation
import SQLite3

@main
private enum AIUsageCoreChecks {
    static func main() async {
        do {
            try self.checkModelsAndRegistry()
            try self.checkClaudeParser()
            try self.checkCodexParser()
            try await self.checkCodexRolloutFallback()
            try self.checkOpenCodeParser()
            try self.checkOpenCodeLocalReader()
            try await self.checkPipelineFallback()
            print("AIUsageCoreChecks: all checks passed")
        } catch {
            fputs("AIUsageCoreChecks failed: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }

    private static func checkModelsAndRegistry() throws {
        try self.expect(
            AIUsageWindow(id: .session, value: .measured(-0.5)).fraction == 0,
            "negative fractions must clamp to zero")
        try self.expect(
            AIUsageWindow(id: .session, value: .measured(1.5)).fraction == 1,
            "fractions above one must clamp")
        let notEnforced = AIUsageWindow(id: .session, value: .notEnforced)
        try self.expect(notEnforced.hasData && notEnforced.fraction == nil, "notEnforced semantics")

        let ids = AIProviderRegistry.descriptors.map(\.id)
        try self.expect(Set(ids).count == ids.count, "provider IDs must be unique")
        try self.expect(ids == [.codex, .claude, .openCode], "provider registry order")
    }

    private static func checkClaudeParser() throws {
        let data = Data(#"""
        {
          "five_hour": {"utilization": 25, "resets_at": "2026-07-22T10:00:00Z"},
          "seven_day": {"utilization": 50, "resets_at": "2026-07-27T00:00:00Z"},
          "limits": ["garbage", {
            "kind": "weekly_scoped",
            "group": "weekly",
            "scope": {"model": {"display_name": "Sonnet"}},
            "percent": 40
          }, 42]
        }
        """#.utf8)
        let snapshot = try ClaudeUsageParser.parse(data: data, rawPlan: "max", multiplier: 20)
        try self.expect(snapshot.window(.session)?.fraction == 0.25, "Claude session window")
        try self.expect(snapshot.window(.weekly)?.fraction == 0.5, "Claude weekly window")
        try self.expect(snapshot.extraWindows.first?.fraction == 0.4, "Claude scoped window")
        try self.expect(snapshot.plan?.displayName == "Max 20×", "Claude plan")

        let weeklyOnly = try ClaudeUsageParser.parse(
            data: Data(#"{"seven_day":{"utilization":33}}"#.utf8),
            rawPlan: nil,
            multiplier: nil)
        try self.expect(weeklyOnly.window(.session)?.value == .notEnforced, "Claude absent session limit")

        let legacy = try ClaudeUsageParser.parse(
            data: Data(#"{"seven_day_sonnet":{"utilization":17}}"#.utf8),
            rawPlan: nil,
            multiplier: nil)
        try self.expect(legacy.extraWindows.first?.fraction == 0.17, "Claude legacy scoped window")

        let populatedAlias = try ClaudeUsageParser.parse(
            data: Data(#"{"seven_day_routines":null,"seven_day_cowork":{"utilization":14}}"#.utf8),
            rawPlan: nil,
            multiplier: nil)
        try self.expect(
            populatedAlias.extraWindows.first?.fraction == 0.14,
            "Claude legacy aliases must skip null siblings")

        let spendOnly = try ClaudeUsageParser.parse(
            data: Data(#"{"five_hour":null,"seven_day":null,"extra_usage":{"is_enabled":true,"used_credits":2500,"monthly_limit":10000}}"#.utf8),
            rawPlan: "enterprise",
            multiplier: nil)
        try self.expect(
            spendOnly.extraWindows.first?.id.rawValue == "claude-spend-limit"
                && spendOnly.extraWindows.first?.fraction == 0.25,
            "Claude spend-limit-only account")
        do {
            _ = try ClaudeUsageParser.parse(
                data: Data(#"{"five_hour":{"unknown":10},"seven_day":{"utilization":33}}"#.utf8),
                rawPlan: nil,
                multiplier: nil)
            throw CheckFailure("Claude malformed session must not mean notEnforced")
        } catch let failure as AIUsageFailure {
            try self.expect(failure.kind == .schemaChanged, "Claude malformed session failure")
        }
    }

    private static func checkCodexParser() throws {
        let chatGPTEndpoint = try CodexUsageEndpointResolver.resolve(configContents:
            "chatgpt_base_url = \"https://chatgpt.com/backend-api/\"\n")
        try self.expect(
            chatGPTEndpoint.absoluteString == "https://chatgpt.com/backend-api/wham/usage",
            "Codex ChatGPT usage endpoint")
        let codexAPIEndpoint = try CodexUsageEndpointResolver.resolve(configContents:
            "chatgpt_base_url = \"https://api.openai.com\"\n")
        try self.expect(
            codexAPIEndpoint.absoluteString == "https://api.openai.com/api/codex/usage",
            "Codex API usage endpoint")
        let legacyEndpoint = try CodexUsageEndpointResolver.resolve(configContents:
            "chatgpt_base_url = \"https://chat.openai.com\"\n")
        try self.expect(
            legacyEndpoint.absoluteString == "https://chat.openai.com/backend-api/wham/usage",
            "Codex legacy ChatGPT endpoint")
        do {
            _ = try CodexUsageEndpointResolver.resolve(
                configContents: "chatgpt_base_url = \"http://example.com\"\n")
            throw CheckFailure("Codex insecure base URL must fail")
        } catch let failure as AIUsageFailure {
            try self.expect(failure.kind == .security, "Codex base URL security failure")
        }

        let data = Data(#"""
        {
          "plan_type": "plus",
          "rate_limit": {
            "primary_window": {"used_percent": 125, "limit_window_seconds": 18000},
            "secondary_window": {"used_percent": 48, "limit_window_seconds": 604800}
          },
          "additional_rate_limits": ["garbage", {
            "limit_name": "GPT-5",
            "metered_feature": "gpt_5_codex",
            "rate_limit": {
              "primary_window": {"used_percent": 20, "limit_window_seconds": 1209600},
              "secondary_window": {"used_percent": 90, "limit_window_seconds": 604800}
            }
          }, {
            "metered_feature": "gpt_5_codex",
            "rate_limit": {
              "primary_window": {"used_percent": 70, "limit_window_seconds": 1209600}
            }
          }, {
            "limit_name": "o3-mini",
            "rate_limit": {
              "secondary_window": {"used_percent": 60, "limit_window_seconds": 604800}
            }
          }, {
            "limit_name": "GPT-5.3-Codex-Spark",
            "metered_feature": "gpt_5_3_codex_spark",
            "rate_limit": {
              "primary_window": {"used_percent": 30, "limit_window_seconds": 18000},
              "secondary_window": {"used_percent": 40, "limit_window_seconds": 604800}
            }
          }, 42]
        }
        """#.utf8)
        let snapshot = try CodexUsageParser.parse(data: data)
        try self.expect(snapshot.window(.session)?.fraction == 1, "Codex fraction clamp")
        try self.expect(snapshot.window(.weekly)?.fraction == 0.48, "Codex weekly window")
        try self.expect(snapshot.extraWindows.count == 4, "Codex extra window count")
        try self.expect(
            snapshot.extraWindows[0].id.rawValue == "codex-gpt-5-codex",
            "Codex extra stable metered-feature ID")
        try self.expect(snapshot.extraWindows[0].title == "GPT-5", "Codex extra display title")
        try self.expect(
            snapshot.extraWindows[0].fraction == 0.2,
            "Codex ordinary extra must prefer its primary window")
        try self.expect(
            snapshot.extraWindows[1].id.rawValue == "codex-o3-mini"
                && snapshot.extraWindows[1].fraction == 0.6,
            "Codex limit-name identity and secondary fallback")
        try self.expect(
            snapshot.extraWindows[2].id.rawValue == "codex-spark"
                && snapshot.extraWindows[2].fraction == 0.3,
            "Codex Spark short window")
        try self.expect(
            snapshot.extraWindows[3].id.rawValue == "codex-spark-weekly"
                && snapshot.extraWindows[3].fraction == 0.4,
            "Codex Spark weekly window")
        try self.expect(
            snapshot.extraWindows[2].title != snapshot.extraWindows[3].title,
            "Codex Spark windows need distinct titles")
        try self.expect(snapshot.plan?.displayName == "Plus", "Codex plan")

        do {
            _ = try CodexUsageParser.parse(data: Data(#"""
            {"rate_limit":{"primary_window":{"unknown":1},"secondary_window":{
              "used_percent":10,"limit_window_seconds":604800
            }}}
            """#.utf8))
            throw CheckFailure("Codex malformed short window must not mean notEnforced")
        } catch let failure as AIUsageFailure {
            try self.expect(failure.kind == .schemaChanged, "Codex malformed short window failure")
        }

        let weeklyOnly = try CodexUsageParser.parse(data: Data(#"""
        {"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":604800}}}
        """#.utf8))
        try self.expect(weeklyOnly.window(.session)?.value == .notEnforced, "Codex absent short limit")

        let individual = try CodexUsageParser.parse(data: Data(#"""
        {
          "plan_type": "enterprise",
          "rate_limit": {
            "primary_window": null,
            "secondary_window": null,
            "individual_limit": {
              "limit": 100000,
              "used": "7761",
              "remaining_percent": 92.239,
              "resets_at": 1782864000
            }
          }
        }
        """#.utf8))
        try self.expect(
            abs((individual.extraWindows.first?.fraction ?? 0) - 0.07761) < 0.000_001,
            "Codex individual monthly limit")
        try self.expect(
            individual.extraWindows.first?.id.rawValue == "codex-individual-limit",
            "Codex individual limit stable ID")

        let unknownDuration = try CodexUsageParser.parse(data: Data(#"""
        {"rate_limit":{"primary_window":{"used_percent":15,"limit_window_seconds":32400}}}
        """#.utf8))
        try self.expect(unknownDuration.window(.weekly) == nil, "Codex unknown duration is not weekly")
        try self.expect(
            unknownDuration.extraWindows.first?.title == "9 小时窗口",
            "Codex unknown duration remains visible")
    }

    private static func checkOpenCodeParser() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let text = #"""
        {"data": {
          "rollingUsage": {"usagePercent": 12.5, "resetInSec": 60},
          "weeklyUsage": {"usedPercent": 34},
          "monthlyUsage": {"utilization": 56}
        }}
        """#
        let snapshot = try OpenCodeUsageParser.parse(text: text, now: now)
        try self.expect(snapshot.window(.session)?.fraction == 0.125, "OpenCode rolling window")
        try self.expect(
            snapshot.window(.session)?.resetsAt == now.addingTimeInterval(60),
            "OpenCode reset offset")
        try self.expect(snapshot.window(.monthly)?.fraction == 0.56, "OpenCode monthly window")

        let ratio = try OpenCodeUsageParser.parse(
            text: #"{"rollingUsage":{"utilization":0.5}}"#)
        try self.expect(ratio.window(.session)?.fraction == 0.5, "OpenCode ratio utilization")

        let genericRatio = try OpenCodeUsageParser.parse(
            text: #"{"rollingWindow":{"usagePercent":0.5}}"#)
        try self.expect(
            genericRatio.window(.session)?.fraction == 0.5,
            "OpenCode direct fractions and alternate window names")

        let embedded = "prefix rollingUsage:{usagePercent:42,resetInSec:120} suffix"
        let embeddedSnapshot = try OpenCodeUsageParser.parse(text: embedded)
        try self.expect(
            embeddedSnapshot.window(.session)?.fraction == 0.42,
            "OpenCode embedded response")

        let seroval = "$R[16]($R[30],$R[41]={"
            + "rollingUsage:$R[42]={status:\"ok\",resetInSec:5944,usagePercent:17},"
            + "weeklyUsage:$R[43]={status:\"ok\",resetInSec:278201,usagePercent:75},"
            + "monthlyUsage:$R[44]={status:\"ok\",resetInSec:880201,usagePercent:91}});"
        let serovalSnapshot = try OpenCodeUsageParser.parse(text: seroval, now: now)
        try self.expect(serovalSnapshot.window(.session)?.fraction == 0.17, "OpenCode Seroval rolling")
        try self.expect(
            serovalSnapshot.window(.session)?.resetsAt == now.addingTimeInterval(5_944),
            "OpenCode Seroval rolling reset")
        try self.expect(serovalSnapshot.window(.weekly)?.fraction == 0.75, "OpenCode Seroval weekly")
        try self.expect(serovalSnapshot.window(.monthly)?.fraction == 0.91, "OpenCode Seroval monthly")

        let onePercent = try OpenCodeUsageParser.parse(
            text: "rollingUsage:$R[1]={usagePercent:1,resetInSec:60}")
        try self.expect(onePercent.window(.session)?.fraction == 0.01, "OpenCode Seroval one percent")

        let nestedWindow = try OpenCodeUsageParser.parse(text: #"""
        {
          "rollingUsage": {"usagePercent": 25, "resetInSec": 600},
          "weeklyUsage": {"window": {"usagePercent": 75, "resetInSec": 7200}}
        }
        """#, now: now)
        try self.expect(nestedWindow.window(.weekly)?.fraction == 0.75, "OpenCode nested window")
        try self.expect(
            nestedWindow.window(.weekly)?.resetsAt == now.addingTimeInterval(7_200),
            "OpenCode nested window reset")

        let totals = try OpenCodeUsageParser.parse(text: #"""
        {
          "rollingUsage": {"used": 25, "limit": 100, "resetInSec": 600},
          "weeklyUsage": {"used": 50, "limit": 200, "resetInSec": 3600}
        }
        """#, now: now)
        try self.expect(totals.window(.session)?.fraction == 0.25, "OpenCode rolling totals")
        try self.expect(totals.window(.weekly)?.fraction == 0.25, "OpenCode weekly totals")

        do {
            _ = try OpenCodeUsageParser.parse(text: "<html>unknown</html>")
            throw CheckFailure("OpenCode unknown schemas must fail")
        } catch let failure as AIUsageFailure {
            try self.expect(failure.kind == .schemaChanged, "OpenCode schema failure kind")
        }
        do {
            _ = try OpenCodeUsageParser.parse(
                text: "rollingUsage:null,weeklyUsage:{usagePercent:60}")
            throw CheckFailure("OpenCode windows must not borrow neighboring fields")
        } catch let failure as AIUsageFailure {
            try self.expect(failure.kind == .schemaChanged, "OpenCode property isolation")
        }
    }

    private static func checkCodexRolloutFallback() async throws {
        let originalHome = getenv("CODEX_HOME").map { String(cString: $0) }
        defer {
            if let originalHome {
                _ = setenv("CODEX_HOME", originalHome, 1)
            } else {
                unsetenv("CODEX_HOME")
            }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsageCoreChecks-Codex-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstHome = root.appendingPathComponent("first", isDirectory: true)
        let firstSessions = firstHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: firstSessions, withIntermediateDirectories: true)
        _ = setenv("CODEX_HOME", firstHome.path, 1)

        let now = Date()
        let olderEvent = now.addingTimeInterval(-7_200)
        let newerEvent = now.addingTimeInterval(-1_800)
        let newerFile = firstSessions.appendingPathComponent("rollout-newer-mtime.jsonl")
        try (self.codexRolloutLine(timestamp: olderEvent, usedPercent: 11) + Data([0x0A]))
            .write(to: newerFile)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-60)],
            ofItemAtPath: newerFile.path)

        let newerPayload = firstSessions.appendingPathComponent("rollout-newer-event.jsonl")
        var payload = self.codexRolloutLine(timestamp: newerEvent, usedPercent: 67)
        payload.append(0x0A)
        payload.append(Data(#"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"unknown":1}}}}"#.utf8))
        payload.append(0x0A)
        payload.append(contentsOf: [0xF0, 0x9F])
        try payload.write(to: newerPayload)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-1_200)],
            ofItemAtPath: newerPayload.path)

        guard let descriptor = AIProviderRegistry.descriptor(for: .codex) else {
            throw CheckFailure("Codex descriptor")
        }
        let first = try await descriptor.pipeline.fetch().result.get()
        try self.expect(first.source.quality == .cached, "Codex rollout fallback quality")
        try self.expect(first.snapshot.window(.session)?.fraction == 0.67, "Codex latest event timestamp")
        try self.expect(
            abs(first.snapshot.capturedAt.timeIntervalSince(newerEvent)) < 1,
            "Codex rollout embedded timestamp")

        let boundaryHome = root.appendingPathComponent("boundary", isDirectory: true)
        let boundarySessions = boundaryHome.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: boundarySessions, withIntermediateDirectories: true)
        _ = setenv("CODEX_HOME", boundaryHome.path, 1)
        let boundaryEvent = now.addingTimeInterval(-900)
        var tail = self.codexRolloutLine(timestamp: boundaryEvent, usedPercent: 82)
        tail.append(0x0A)
        let oneMiB = 1_048_576
        try self.expect(tail.count < oneMiB, "Codex rollout boundary fixture size")
        tail.append(Data(repeating: 0x0A, count: oneMiB - tail.count))
        var boundaryData = Data(repeating: 0x78, count: 31)
        boundaryData.append(0x0A)
        boundaryData.append(tail)
        let boundaryFile = boundarySessions.appendingPathComponent("rollout-boundary.jsonl")
        try boundaryData.write(to: boundaryFile)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-300)],
            ofItemAtPath: boundaryFile.path)

        let boundary = try await descriptor.pipeline.fetch().result.get()
        try self.expect(boundary.snapshot.window(.session)?.fraction == 0.82, "Codex 1 MiB line boundary")
    }

    private static func codexRolloutLine(timestamp: Date, usedPercent: Int) -> Data {
        Data(#"{"timestamp":\#(timestamp.timeIntervalSince1970),"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":\#(usedPercent),"window_minutes":300},"secondary":{"used_percent":40,"window_minutes":10080},"plan_type":"pro"}}}"#.utf8)
    }

    private static func checkOpenCodeLocalReader() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsageCoreChecks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("opencode.db")

        var database: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK, let database else {
            throw CheckFailure("create OpenCode fixture database")
        }
        defer { sqlite3_close(database) }
        try self.executeSQL(
            "CREATE TABLE message (id TEXT PRIMARY KEY, data TEXT NOT NULL, time_created INTEGER)",
            database: database)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows: [(hoursAgo: Double, cost: Double)] = [(1, 6), (6, 3)]
        for (index, row) in rows.enumerated() {
            let created = Int64(now.addingTimeInterval(-row.hoursAgo * 3600).timeIntervalSince1970 * 1000)
            let payload = #"{"providerID":"opencode-go","role":"assistant","cost":\#(row.cost),"time":{"created":\#(created)}}"#
            let escaped = payload.replacingOccurrences(of: "'", with: "''")
            try self.executeSQL(
                "INSERT INTO message VALUES ('m\(index)', '\(escaped)', \(created))",
                database: database)
        }

        let snapshot = try OpenCodeLocalUsageReader(databaseURL: databaseURL).fetch(now: now)
        try self.expect(snapshot.window(.session)?.fraction == 0.5, "OpenCode local rolling estimate")
        try self.expect(snapshot.window(.weekly)?.fraction == 0.3, "OpenCode local weekly estimate")
        try self.expect(snapshot.window(.monthly)?.fraction == 0.15, "OpenCode local monthly estimate")
    }

    private static func executeSQL(_ sql: String, database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CheckFailure("execute SQLite fixture statement")
        }
    }

    private static func checkPipelineFallback() async throws {
        let networkFailure = AIUsageFailure(.network, "offline")
        let first = StubStrategy(
            id: "first",
            result: .failure(networkFailure),
            fallbackKinds: [.network])
        let second = StubStrategy(
            id: "second",
            result: .success(Self.result(providerID: .codex)))
        let outcome = await AIUsageFetchPipeline(
            providerID: .codex,
            strategies: [first, second]).fetch()
        _ = try outcome.result.get()
        try self.expect(outcome.attempts.count == 2, "fallback attempt count")
        try self.expect(outcome.attempts[0].failure == networkFailure, "fallback failure trace")

        let missing = AIUsageFailure(.credentialMissing, "missing")
        let unavailable = StubStrategy(
            id: "unavailable",
            availability: .unavailable(missing),
            result: .failure(missing))
        let available = StubStrategy(
            id: "available",
            result: .success(Self.result(providerID: .claude)))
        let skipped = await AIUsageFetchPipeline(
            providerID: .claude,
            strategies: [unavailable, available]).fetch()
        _ = try skipped.result.get()
        try self.expect(!skipped.attempts[0].wasAvailable, "unavailable strategy trace")

        let unavailableFallback = await AIUsageFetchPipeline(
            providerID: .codex,
            strategies: [first, StubStrategy(
                id: "missing-fallback",
                availability: .unavailable(missing),
                result: .failure(missing))]).fetch()
        guard case let .failure(originalFailure) = unavailableFallback.result else {
            throw CheckFailure("fallback exhaustion must fail")
        }
        try self.expect(originalFailure == networkFailure, "executed failure must outrank unavailable fallback")

        let mismatch = await AIUsageFetchPipeline(
            providerID: .codex,
            strategies: [available]).fetch()
        guard case let .failure(failure) = mismatch.result else {
            throw CheckFailure("provider mismatch must fail")
        }
        try self.expect(failure.kind == .schemaChanged, "provider mismatch failure")

        let contextualPipeline = AIUsageFetchPipeline(
            providerID: .claude,
            strategies: [UserInteractionStrategy()])
        let automatic = await contextualPipeline.fetch()
        guard case let .failure(automaticFailure) = automatic.result else {
            throw CheckFailure("automatic fetch must not enable credential prompts")
        }
        try self.expect(
            automaticFailure.kind == .credentialMissing,
            "automatic fetch context propagation")
        _ = try await contextualPipeline.fetch(context: .userInitiated).result.get()

        let cancellationPipeline = AIUsageFetchPipeline(
            providerID: .codex,
            strategies: [CancellationIgnoringStrategy()])
        let cancellationTask = Task { await cancellationPipeline.fetch() }
        try? await Task.sleep(nanoseconds: 10_000_000)
        cancellationTask.cancel()
        let cancelled = await cancellationTask.value
        guard case let .failure(cancelledFailure) = cancelled.result else {
            throw CheckFailure("cancelled pipeline must not return a late success")
        }
        try self.expect(cancelledFailure.kind == .cancelled, "late cancellation propagation")
    }

    private static func result(providerID: AIProviderID) -> AIUsageFetchResult {
        AIUsageFetchResult(
            snapshot: AIUsageSnapshot(
                providerID: providerID,
                windows: [AIUsageWindow(id: .session, value: .measured(0.25))]),
            source: AIUsageSource(
                id: "check",
                label: "Check",
                kind: .local,
                quality: .live))
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure(message) }
    }
}

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct StubStrategy: AIUsageFetchStrategy {
    let id: String
    let kind = AIUsageFetchKind.local
    let availabilityResult: AIStrategyAvailability
    let result: Result<AIUsageFetchResult, AIUsageFailure>
    let fallbackKinds: Set<AIUsageFailure.Kind>

    init(
        id: String,
        availability: AIStrategyAvailability = .available,
        result: Result<AIUsageFetchResult, AIUsageFailure>,
        fallbackKinds: Set<AIUsageFailure.Kind> = [])
    {
        self.id = id
        self.availabilityResult = availability
        self.result = result
        self.fallbackKinds = fallbackKinds
    }

    func availability(context _: AIUsageFetchContext) async -> AIStrategyAvailability {
        self.availabilityResult
    }
    func fetch(context _: AIUsageFetchContext) async throws -> AIUsageFetchResult {
        try self.result.get()
    }
    func shouldFallback(after failure: AIUsageFailure) -> Bool {
        self.fallbackKinds.contains(failure.kind)
    }
}

private struct UserInteractionStrategy: AIUsageFetchStrategy {
    let id = "user-interaction"
    let kind = AIUsageFetchKind.oauth

    func fetch(context: AIUsageFetchContext) async throws -> AIUsageFetchResult {
        guard context.allowsCredentialPrompt else {
            throw AIUsageFailure(.credentialMissing, "interaction disabled")
        }
        return AIUsageFetchResult(
            snapshot: AIUsageSnapshot(
                providerID: .claude,
                windows: [AIUsageWindow(id: .session, value: .measured(0.25))]),
            source: AIUsageSource(
                id: self.id,
                label: "Check",
                kind: .oauth,
                quality: .live))
    }
}

private struct CancellationIgnoringStrategy: AIUsageFetchStrategy {
    let id = "cancellation-ignoring"
    let kind = AIUsageFetchKind.local

    func fetch(context _: AIUsageFetchContext) async throws -> AIUsageFetchResult {
        usleep(50_000)
        return AIUsageFetchResult(
            snapshot: AIUsageSnapshot(
                providerID: .codex,
                windows: [AIUsageWindow(id: .session, value: .measured(0.1))]),
            source: AIUsageSource(
                id: self.id,
                label: "Check",
                kind: .local,
                quality: .live))
    }
}
