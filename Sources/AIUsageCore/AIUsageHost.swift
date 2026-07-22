import Darwin
import Foundation
import LocalAuthentication
import Security

struct AIHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
}

protocol AIHTTPTransport: Sendable {
    func send(_ request: URLRequest, allowedHosts: Set<String>) async throws -> AIHTTPResponse
}

private final class AIRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void)
    {
        completionHandler(nil)
    }
}

/// 凭证请求只允许发往 provider 声明的 HTTPS host，并拒绝所有重定向，防止认证头跨域泄漏。
final class AIURLSessionHTTPTransport: AIHTTPTransport, @unchecked Sendable {
    static let shared = AIURLSessionHTTPTransport()

    private let redirectBlocker: AIRedirectBlocker
    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectBlocker = AIRedirectBlocker()
        self.redirectBlocker = redirectBlocker
        self.session = URLSession(
            configuration: configuration,
            delegate: redirectBlocker,
            delegateQueue: nil)
    }

    func send(_ request: URLRequest, allowedHosts: Set<String>) async throws -> AIHTTPResponse {
        guard request.url?.scheme?.lowercased() == "https",
              let host = request.url?.host?.lowercased(),
              allowedHosts.contains(host)
        else {
            throw AIUsageFailure(.security, "已拒绝向未授权域名发送用量凭证")
        }

        do {
            let (data, response) = try await self.session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AIUsageFailure(.network, "服务返回了无效响应")
            }
            return AIHTTPResponse(data: data, statusCode: http.statusCode)
        } catch let failure as AIUsageFailure {
            throw failure
        } catch is CancellationError {
            throw AIUsageFailure(.cancelled, "请求已取消")
        } catch let error as URLError {
            switch error.code {
            case .cancelled:
                throw AIUsageFailure(.cancelled, "请求已取消")
            case .timedOut:
                throw AIUsageFailure(.timeout, "请求超时")
            default:
                throw AIUsageFailure(.network, "网络请求失败：\(error.localizedDescription)")
            }
        } catch {
            throw AIUsageFailure(.network, "网络请求失败：\(error.localizedDescription)")
        }
    }
}

enum AIJSON {
    static func number(_ raw: Any?) -> Double? {
        if raw is Bool { return nil }
        if let value = raw as? NSNumber { return value.doubleValue }
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? Int64 { return Double(value) }
        if let value = raw as? String { return Double(value) }
        return nil
    }

    static func fraction(percent raw: Any?) -> Double? {
        guard let value = self.number(raw), value.isFinite else { return nil }
        return min(max(value / 100, 0), 1)
    }

    static func date(_ raw: Any?) -> Date? {
        if let text = raw as? String {
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: text) { return date }
            let seconds = ISO8601DateFormatter()
            seconds.formatOptions = [.withInternetDateTime]
            if let date = seconds.date(from: text) { return date }
            if let value = Double(text) { return self.unixDate(value) }
            return nil
        }
        guard let value = self.number(raw) else { return nil }
        return self.unixDate(value)
    }

    private static func unixDate(_ value: Double) -> Date? {
        guard value.isFinite, value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 10_000_000_000 ? value / 1000 : value)
    }
}

struct AIProcessResult: Sendable {
    let output: Data
    let status: Int32
}

enum AIBoundedProcessRunner {
    static func run(
        executableCandidates: [String],
        arguments: [String],
        timeout: TimeInterval,
        captureOutput: Bool = false) -> AIProcessResult?
    {
        let fileManager = FileManager.default
        guard let executable = executableCandidates.first(where: fileManager.isExecutableFile(atPath:)) else {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = captureOutput ? output : FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = finished.wait(timeout: .now() + 1)
            return nil
        }
        let data = captureOutput ? output.fileHandleForReading.readDataToEndOfFile() : Data()
        return AIProcessResult(output: data, status: process.terminationStatus)
    }
}

/// 通过系统 security 工具只读通用密码；后台刷新改用禁止授权 UI 的 Security.framework 查询。
enum AISecureCredentialReader {
    private static let uiFailPolicy = AISecureCredentialReader.resolveUIFailPolicy()

    static func readGenericPassword(
        service: String,
        account: String? = nil,
        timeout: TimeInterval = 5,
        allowDirectFallback: Bool = false,
        allowsUserInteraction: Bool = true) -> Data?
    {
        if allowsUserInteraction {
            var arguments = ["find-generic-password", "-s", service]
            if let account { arguments += ["-a", account] }
            arguments.append("-w")
            let result = AIBoundedProcessRunner.run(
                executableCandidates: ["/usr/bin/security"],
                arguments: arguments,
                timeout: timeout,
                captureOutput: true)
            if let result, result.status == 0, !result.output.isEmpty { return result.output }
        }
        guard allowDirectFallback || !allowsUserInteraction else { return nil }
        return self.directRead(
            service: service,
            account: account,
            allowsUserInteraction: allowsUserInteraction)
    }

    private static func directRead(
        service: String,
        account: String?,
        allowsUserInteraction: Bool) -> Data?
    {
        for useDataProtection in [false, true] {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            if let account { query[kSecAttrAccount as String] = account }
            if useDataProtection { query[kSecUseDataProtectionKeychain as String] = true }
            if !allowsUserInteraction {
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
                // 旧版 macOS 仅设 interactionNotAllowed 仍可能显示 Allow/Deny；
                // 动态取得 deprecated 常量的真实值，同时保留现代编译器零告警。
                query[kSecUseAuthenticationUI as String] = self.uiFailPolicy as CFString
            }
            var result: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
               let data = result as? Data, !data.isEmpty
            {
                return data
            }
        }
        return nil
    }

    private static func resolveUIFailPolicy() -> String {
        let securityPath = "/System/Library/Frameworks/Security.framework/Security"
        guard let handle = dlopen(securityPath, RTLD_NOW) else { return "u_AuthUIF" }
        defer { dlclose(handle) }
        guard let symbol = dlsym(handle, "kSecUseAuthenticationUIFail") else {
            return "u_AuthUIF"
        }
        let valuePointer = symbol.assumingMemoryBound(to: CFString?.self)
        return (valuePointer.pointee as String?) ?? "u_AuthUIF"
    }
}

enum AIKnownPaths {
    static var homeDirectory: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func codexHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            return URL(fileURLWithPath: raw, isDirectory: true)
        }
        return self.homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }
}

extension String {
    var aiSafeHeaderValue: String? {
        self.contains("\r") || self.contains("\n") ? nil : self
    }
}
