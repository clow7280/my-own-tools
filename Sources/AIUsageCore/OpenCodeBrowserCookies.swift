import CommonCrypto
import CryptoKit
import Foundation
import SQLite3

struct OpenCodeCookieCandidate: Sendable {
    let header: String
    let fingerprint: String
    let sourceID: String
    let expiresAt: Date?

    func isExpired(at date: Date = Date()) -> Bool {
        self.expiresAt.map { $0 <= date } ?? false
    }
}

/// 只读导入 Chromium 系浏览器中 `opencode.ai` 的认证 Cookie。
enum OpenCodeBrowserCookieReader {
    private struct Browser {
        let name: String
        let root: URL
        let keychainService: String
        let keychainAccount: String
    }

    private final class ValidatedCache: @unchecked Sendable {
        private let lock = NSLock()
        private var candidate: OpenCodeCookieCandidate?

        func current(now: Date = Date()) -> OpenCodeCookieCandidate? {
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.candidate?.isExpired(at: now) == true { self.candidate = nil }
            return self.candidate
        }

        func store(_ candidate: OpenCodeCookieCandidate) {
            self.lock.lock()
            self.candidate = candidate
            self.lock.unlock()
        }

        func invalidate(fingerprint: String) {
            self.lock.lock()
            if self.candidate?.fingerprint == fingerprint { self.candidate = nil }
            self.lock.unlock()
        }
    }

    private static let validatedCache = ValidatedCache()
    private static let maximumCandidatesPerBrowser = 4

    private static var browsers: [Browser] {
        let home = AIKnownPaths.homeDirectory
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            Browser(
                name: "Chrome",
                root: home.appendingPathComponent("Google/Chrome", isDirectory: true),
                keychainService: "Chrome Safe Storage",
                keychainAccount: "Chrome"),
            Browser(
                name: "Arc",
                root: home.appendingPathComponent("Arc/User Data", isDirectory: true),
                keychainService: "Arc Safe Storage",
                keychainAccount: "Arc"),
            Browser(
                name: "Brave",
                root: home.appendingPathComponent("BraveSoftware/Brave-Browser", isDirectory: true),
                keychainService: "Brave Safe Storage",
                keychainAccount: "Brave"),
            Browser(
                name: "Edge",
                root: home.appendingPathComponent("Microsoft Edge", isDirectory: true),
                keychainService: "Microsoft Edge Safe Storage",
                keychainAccount: "Microsoft Edge"),
            Browser(
                name: "Vivaldi",
                root: home.appendingPathComponent("Vivaldi", isDirectory: true),
                keychainService: "Vivaldi Safe Storage",
                keychainAccount: "Vivaldi"),
            Browser(
                name: "Chromium",
                root: home.appendingPathComponent("Chromium", isDirectory: true),
                keychainService: "Chromium Safe Storage",
                keychainAccount: "Chromium"),
        ]
    }

    static func validatedCandidate() -> OpenCodeCookieCandidate? {
        self.validatedCache.current()
    }

    static func markValidated(_ candidate: OpenCodeCookieCandidate) {
        self.validatedCache.store(candidate)
    }

    static func invalidateValidated(_ candidate: OpenCodeCookieCandidate) {
        self.validatedCache.invalidate(fingerprint: candidate.fingerprint)
    }

    /// 每次只解密一个浏览器；调用方验证失败后再取下一批，避免首次刷新连续触发多个 Keychain 请求。
    static func candidateBatch(
        startingAt startIndex: Int,
        excluding excluded: Set<String> = [],
        allowsUserInteraction: Bool)
        -> (candidates: [OpenCodeCookieCandidate], nextBrowserIndex: Int)?
    {
        let fileManager = FileManager.default
        let browsers = self.browsers
        for index in max(startIndex, 0)..<browsers.count {
            let browser = browsers[index]
            guard fileManager.fileExists(atPath: browser.root.path) else { continue }
            let databases = self.cookieDatabases(browser: browser)
            guard !databases.isEmpty else { continue }

            // 先尝试明文 Cookie 与旧版 Chromium 的固定密码，成功前不访问 Safe Storage。
            // 返回当前 browser index，让候选被远端拒绝后再进入同一浏览器的 Keychain 阶段。
            let legacyCandidates = self.cookieCandidates(
                browserName: browser.name,
                databases: databases,
                passwords: ["peanuts"],
                excluding: excluded)
            if !legacyCandidates.isEmpty {
                return (Array(legacyCandidates.prefix(self.maximumCandidatesPerBrowser)), index)
            }

            let keychainSecret = AISecureCredentialReader.readGenericPassword(
                service: browser.keychainService,
                account: browser.keychainAccount,
                allowDirectFallback: true,
                allowsUserInteraction: allowsUserInteraction
            ).flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let keychainSecret, !keychainSecret.isEmpty else { continue }
            let browserCandidates = self.cookieCandidates(
                browserName: browser.name,
                databases: databases,
                passwords: [keychainSecret],
                excluding: excluded)
            if !browserCandidates.isEmpty {
                return (Array(browserCandidates.prefix(self.maximumCandidatesPerBrowser)), index + 1)
            }
        }
        return nil
    }

    private static func cookieCandidates(
        browserName: String,
        databases: [(profile: String, url: URL)],
        passwords: [String],
        excluding excluded: Set<String>) -> [OpenCodeCookieCandidate]
    {
        var candidates: [OpenCodeCookieCandidate] = []
        var seen = Set<String>()
        databaseLoop: for database in databases {
            for password in passwords {
                for candidate in self.readCookies(
                    database: database.url,
                    password: password,
                    sourceID: browserName + ":" + database.profile)
                where !excluded.contains(candidate.fingerprint)
                    && seen.insert(candidate.fingerprint).inserted
                {
                    candidates.append(candidate)
                    if candidates.count == self.maximumCandidatesPerBrowser {
                        break databaseLoop
                    }
                }
            }
        }
        return candidates
    }

    private static func cookieDatabases(browser: Browser) -> [(profile: String, url: URL)] {
        let fileManager = FileManager.default
        var result: [(profile: String, url: URL, modifiedAt: Date)] = []
        for profile in self.profileDirectories(browser.root) {
            for relativePath in ["Cookies", "Network/Cookies"] {
                let url = browser.root
                    .appendingPathComponent(profile, isDirectory: true)
                    .appendingPathComponent(relativePath, isDirectory: false)
                    .standardizedFileURL
                guard url.path.hasPrefix(browser.root.standardizedFileURL.path + "/"),
                      fileManager.fileExists(atPath: url.path)
                else { continue }
                let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                result.append((profile, url, modifiedAt))
            }
        }
        return result.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
            return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
        }.map { ($0.profile, $0.url) }
    }

    private static func profileDirectories(_ root: URL) -> [String] {
        var profiles: [String] = []
        let localState = root.appendingPathComponent("Local State", isDirectory: false)
        if let data = try? Data(contentsOf: localState),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let profile = json["profile"] as? [String: Any],
           let cache = profile["info_cache"] as? [String: Any]
        {
            profiles.append(contentsOf: cache.keys)
        }
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path) {
            profiles.append(contentsOf: entries.filter { $0 == "Default" || $0.hasPrefix("Profile ") })
        }

        var seen = Set<String>()
        return profiles.filter { profile in
            guard !profile.isEmpty, profile != ".", profile != "..",
                  !profile.contains("/"), !profile.contains("\\")
            else { return false }
            let url = root.appendingPathComponent(profile, isDirectory: true).standardizedFileURL
            guard url.deletingLastPathComponent() == root.standardizedFileURL else { return false }
            return seen.insert(profile).inserted
        }.sorted { lhs, rhs in
            if lhs == "Default" { return true }
            if rhs == "Default" { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func readCookies(
        database url: URL,
        password: String,
        sourceID: String) -> [OpenCodeCookieCandidate]
    {
        var database: OpaquePointer?
        let status = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil)
        guard status == SQLITE_OK, let database else {
            if let database { sqlite3_close(database) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 500)

        let query = """
        SELECT name, host_key, value, encrypted_value, expires_utc
        FROM cookies
        WHERE name IN ('auth', '__Host-auth')
          AND host_key IN ('opencode.ai', '.opencode.ai')
          AND (expires_utc = 0 OR expires_utc > ?)
        ORDER BY last_access_utc DESC
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { return [] }
        defer { sqlite3_finalize(statement) }

        let chromiumEpochOffset: TimeInterval = 11_644_473_600
        let now = Int64((Date().timeIntervalSince1970 + chromiumEpochOffset) * 1_000_000)
        sqlite3_bind_int64(statement, 1, now)

        var candidates: [OpenCodeCookieCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "auth"
            let host = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let plain = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
            let expires = sqlite3_column_int64(statement, 4)
            let expiresAt = expires > 0
                ? Date(timeIntervalSince1970: TimeInterval(expires) / 1_000_000 - chromiumEpochOffset)
                : nil

            var values: [String] = []
            if !plain.isEmpty { values.append(plain) }
            if let bytes = sqlite3_column_blob(statement, 3) {
                let count = Int(sqlite3_column_bytes(statement, 3))
                if count > 3 {
                    let encrypted = Data(bytes: bytes, count: count)
                    if let value = self.decrypt(encrypted, password: password, host: host) {
                        values.append(value)
                    }
                }
            }
            for value in values {
                guard let header = self.header(name: name, value: value) else { continue }
                let digest = SHA256.hash(data: Data(header.utf8))
                    .map { String(format: "%02x", $0) }.joined()
                candidates.append(OpenCodeCookieCandidate(
                    header: header,
                    fingerprint: digest,
                    sourceID: sourceID,
                    expiresAt: expiresAt))
            }
        }
        return candidates
    }

    private static func header(name: String, value: String) -> String? {
        guard name == "auth" || name == "__Host-auth", !value.isEmpty else { return nil }
        for scalar in value.unicodeScalars {
            let byte = scalar.value
            let allowed = byte == 0x21
                || (0x23...0x2B).contains(byte)
                || (0x2D...0x3A).contains(byte)
                || (0x3C...0x5B).contains(byte)
                || (0x5D...0x7E).contains(byte)
            guard allowed else { return nil }
        }
        return name + "=" + value
    }

    private static func decrypt(_ data: Data, password: String, host: String) -> String? {
        guard data.count > 3,
              data.prefix(3) == Data("v10".utf8) || data.prefix(3) == Data("v11".utf8)
        else {
            return String(data: data, encoding: .utf8)
        }

        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        let salt = [UInt8]("saltysalt".utf8)
        let derivation = password.withCString { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes,
                    password.lengthOfBytes(using: .utf8),
                    saltBytes.bindMemory(to: UInt8.self).baseAddress,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    &key,
                    key.count)
            }
        }
        guard derivation == kCCSuccess else { return nil }

        let cipher = Data(data.dropFirst(3))
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: cipher.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outputLength = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                cipher.withUnsafeBytes { cipherBytes in
                    output.withUnsafeMutableBytes { outputBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            cipherBytes.baseAddress,
                            cipher.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }

        var plaintext = Data(output.prefix(outputLength))
        let hostDigest = Data(SHA256.hash(data: Data(host.utf8)))
        if plaintext.count > hostDigest.count, plaintext.starts(with: hostDigest) {
            plaintext.removeFirst(hostDigest.count)
        }
        return String(data: plaintext, encoding: .utf8)
    }
}
