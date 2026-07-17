import Foundation
import Security

/// 单个 AI 提供方的用量快照（百分比统一为 0~1）
struct AIUsage {
    struct Model {
        var name: String        // "Fable" / "GPT-5.3-Codex-Spark"
        var percent: Double     // 0~1
        var resetsAt: Date?
    }

    var fiveHour: Double?       // 5 小时滚动窗；nil 且有 7d 数据 = 限额暂时取消
    var sevenDay: Double?       // 7 天窗
    var fiveHourResetsAt: Date?
    var sevenDayResetsAt: Date?
    var models: [Model] = []
    var plan: String?           // 订阅计划原始值（pro / max…）
    var error: String?         // 读取失败时的原因（供 AI 页显示）

    /// 订阅计划原始值 → 徽章文本（"pro"→"Pro"，"max…20x"→"Max 20×"）
    static func planBadge(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let lower = raw.lowercased()
        if lower.contains("max") {
            if lower.contains("20") { return "Max 20×" }
            if lower.contains("5") { return "Max 5×" }
            return "Max"
        }
        if lower.contains("enterprise") { return "Enterprise" }
        if lower.contains("team") { return "Team" }
        if lower.contains("plus") { return "Plus" }
        if lower.contains("pro") { return "Pro" }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

// MARK: - Claude

/// Claude：从 Keychain 读 Claude Code 的 OAuth token，打 oauth/usage 端点。
/// 见 memory `ai-usage-endpoints`。
enum ClaudeUsageReader {
    static func fetch(_ completion: @escaping (AIUsage) -> Void) {
        guard let creds = credentials() else {
            return completion(AIUsage(error: "未找到 Claude 凭证"))
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/1.0.0", forHTTPHeaderField: "User-Agent")  // 必须，否则严格限流
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return completion(AIUsage(error: code == 401 ? "Claude token 已过期" : "Claude 请求失败(\(code))"))
            }
            var usage = parse(json)
            usage.plan = creds.plan     // 用量端点不带计划，取凭证里的 subscriptionType
            completion(usage)
        }.resume()
    }

    private static func parse(_ json: [String: Any]) -> AIUsage {
        var usage = AIUsage()
        if let five = json["five_hour"] as? [String: Any] {
            usage.fiveHour = (five["utilization"] as? Double).map { $0 / 100 }
            usage.fiveHourResetsAt = isoDate(five["resets_at"])
        }
        if let seven = json["seven_day"] as? [String: Any] {
            usage.sevenDay = (seven["utilization"] as? Double).map { $0 / 100 }
            usage.sevenDayResetsAt = isoDate(seven["resets_at"])
        }
        // 分模型用量在 limits[]（weekly_scoped，scope.model.display_name = Fable/Opus…）
        if let limits = json["limits"] as? [[String: Any]] {
            for limit in limits where (limit["kind"] as? String) == "weekly_scoped" {
                guard let scope = limit["scope"] as? [String: Any],
                      let model = scope["model"] as? [String: Any],
                      let name = model["display_name"] as? String,
                      let percent = limit["percent"] as? Double else { continue }
                usage.models.append(.init(name: name, percent: percent / 100, resetsAt: isoDate(limit["resets_at"])))
            }
        }
        return usage
    }

    /// 读 Claude Code 的 OAuth 凭证 JSON（token + 订阅计划）。
    /// 优先用 `security` 子进程读 Keychain（Keychain 视调用方为受信的 security，
    /// 绕开"自签名 app 读他人 Keychain 项反复弹框"的坑）；失败再退回文件。
    private static func credentials() -> (token: String, plan: String?)? {
        var data = securityRead(service: "Claude Code-credentials")
        if data == nil {
            let path = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
            data = try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return (token, oauth["subscriptionType"] as? String)
    }

    /// `/usr/bin/security find-generic-password -s <service> -w`，带硬超时避免卡死
    private static func securityRead(service: String) -> Data? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }

        // 5 秒超时：若因未授权而挂起，杀掉子进程而非拖死整轮采样
        let deadline = DispatchTime.now() + 5
        let waiter = DispatchQueue(label: "myowntool.security.wait")
        var timedOut = false
        waiter.async {
            if proc.waitUntilExitOrTimeout(deadline) == false {
                timedOut = true
                proc.terminate()
            }
        }
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard !timedOut, proc.terminationStatus == 0 else { return nil }
        return out.isEmpty ? nil : out
    }
}

private extension Process {
    /// 等待退出，超时返回 false
    func waitUntilExitOrTimeout(_ deadline: DispatchTime) -> Bool {
        while isRunning {
            if DispatchTime.now() >= deadline { return false }
            usleep(50_000)
        }
        return true
    }
}

// MARK: - Codex

/// Codex：读 ~/.codex/auth.json 的 access token，打 wham/usage 端点；离线时读 rollout 兜底。
enum CodexUsageReader {
    static func fetch(_ completion: @escaping (AIUsage) -> Void) {
        guard let creds = credentials() else {
            return completion(AIUsage(error: "未找到 Codex 凭证"))
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(creds.token)", forHTTPHeaderField: "Authorization")
        req.setValue(creds.accountID, forHTTPHeaderField: "chatgpt-account-id")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "originator")
        req.setValue("codex_cli_rs/0.144.1", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if let data, code == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                completion(parse(json))
            } else if var fallback = rolloutFallback() {
                fallback.error = "（离线快照）"
                completion(fallback)
            } else {
                completion(AIUsage(error: code == 401 ? "Codex token 已过期" : "Codex 请求失败(\(code))"))
            }
        }.resume()
    }

    private static func parse(_ json: [String: Any]) -> AIUsage {
        var usage = AIUsage()
        usage.plan = json["plan_type"] as? String
        if let rl = json["rate_limit"] as? [String: Any] {
            applyWindow(rl["primary_window"], to: &usage)
            applyWindow(rl["secondary_window"], to: &usage)
        }
        if let additional = json["additional_rate_limits"] as? [[String: Any]] {
            for entry in additional {
                guard let name = entry["limit_name"] as? String,
                      let rl = entry["rate_limit"] as? [String: Any],
                      let win = rl["primary_window"] as? [String: Any],
                      let pct = win["used_percent"] as? Double else { continue }
                usage.models.append(.init(name: name, percent: pct / 100,
                                          resetsAt: unixDate(win["reset_at"])))
            }
        }
        return usage
    }

    /// 按 limit_window_seconds 归类窗口：18000=5h，604800=7d（不按 primary/secondary 位置硬编码）
    private static func applyWindow(_ raw: Any?, to usage: inout AIUsage) {
        guard let win = raw as? [String: Any],
              let seconds = win["limit_window_seconds"] as? Double,
              let pct = win["used_percent"] as? Double else { return }
        let value = pct / 100
        let resets = unixDate(win["reset_at"])
        if seconds <= 21600 {           // ≤6h 视为 5 小时窗
            usage.fiveHour = value
            usage.fiveHourResetsAt = resets
        } else {                        // 其余视为周窗
            usage.sevenDay = value
            usage.sevenDayResetsAt = resets
        }
    }

    private static func credentials() -> (token: String, accountID: String)? {
        let path = ("~/.codex/auth.json" as NSString).expandingTildeInPath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = json["tokens"] as? [String: Any],
              let token = tokens["access_token"] as? String,
              let account = tokens["account_id"] as? String else { return nil }
        return (token, account)
    }

    /// 最新 rollout 文件里最后一个 token_count 事件的 rate_limits
    private static func rolloutFallback() -> AIUsage? {
        let base = ("~/.codex/sessions" as NSString).expandingTildeInPath
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: base) else { return nil }
        var newest: (path: String, date: Date)?
        for case let rel as String in enumerator where rel.hasSuffix(".jsonl") {
            let full = base + "/" + rel
            guard let mod = (try? fm.attributesOfItem(atPath: full))?[.modificationDate] as? Date else { continue }
            if newest == nil || mod > newest!.date { newest = (full, mod) }
        }
        guard let path = newest?.path,
              let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        // 逆序找最后一个带 rate_limits 的行
        for line in content.split(separator: "\n").reversed() {
            guard line.contains("\"rate_limits\""),
                  let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let info = obj["rate_limits"] as? [String: Any] ?? (obj["info"] as? [String: Any]).flatMap({ _ in obj["rate_limits"] as? [String: Any] }) else { continue }
            var usage = AIUsage()
            usage.plan = info["plan_type"] as? String
            applyRolloutWindow(info["primary"], to: &usage)
            applyRolloutWindow(info["secondary"], to: &usage)
            return usage
        }
        return nil
    }

    /// rollout 用 window_minutes（300=5h，10080=7d）
    private static func applyRolloutWindow(_ raw: Any?, to usage: inout AIUsage) {
        guard let win = raw as? [String: Any],
              let minutes = win["window_minutes"] as? Double,
              let pct = win["used_percent"] as? Double else { return }
        let value = pct / 100
        let resets = unixDate(win["resets_at"])
        if minutes <= 360 {
            usage.fiveHour = value
            usage.fiveHourResetsAt = resets
        } else {
            usage.sevenDay = value
            usage.sevenDayResetsAt = resets
        }
    }
}

// MARK: - 日期解析

private let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private func isoDate(_ raw: Any?) -> Date? {
    guard let s = raw as? String else { return nil }
    return isoFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

private func unixDate(_ raw: Any?) -> Date? {
    guard let n = raw as? Double else { return nil }
    return Date(timeIntervalSince1970: n)
}
