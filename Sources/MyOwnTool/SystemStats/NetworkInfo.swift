import Foundation
import SystemConfiguration

/// 当前互联网出口：默认路由接口（SCDynamicStore）+ 该接口的内网 IPv4
enum RouteInfo {
    struct Info {
        var bsdName: String        // en0
        var displayName: String?   // Wi-Fi
        var localIP: String?       // 172.20.10.2
    }

    static func current() -> Info? {
        guard let store = SCDynamicStoreCreate(nil, "myowntool" as CFString, nil, nil),
              let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let bsd = value["PrimaryInterface"] as? String else { return nil }
        return Info(bsdName: bsd, displayName: displayName(of: bsd), localIP: localIPv4(of: bsd))
    }

    private static func displayName(of bsd: String) -> String? {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return nil }
        for interface in interfaces where SCNetworkInterfaceGetBSDName(interface) as String? == bsd {
            return SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
        }
        return nil
    }

    private static func localIPv4(of bsd: String) -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }

        var pointer = list
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == bsd,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            var sin = sockaddr_in()
            memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &sin.sin_addr, &buffer, socklen_t(buffer.count)) != nil else { continue }
            return String(cString: buffer)
        }
        return nil
    }
}

/// 国内外出口公网 IP：国内经 cip.cc、国外经 ip.im/info（均需 curl UA 才返回纯文本）。
/// 成功缓存 5 分钟，失败 30 秒后允许重试；回调在主线程。
final class PublicIPFetcher {
    struct Result {
        var ip: String
        var note: String?   // 国内为运营商，国外为国家代码
    }

    private(set) var domestic: Result?
    private(set) var foreign: Result?

    private var lastFetch: Date?
    private var inFlight = false
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.httpAdditionalHeaders = ["User-Agent": "curl/8.4.0"]
        return URLSession(configuration: config)
    }()

    func refreshIfStale(completion: @escaping () -> Void) {
        if let lastFetch {
            let ttl: TimeInterval = (domestic == nil || foreign == nil) ? 30 : 300
            if Date().timeIntervalSince(lastFetch) < ttl { return }
        }
        guard !inFlight else { return }
        inFlight = true

        let group = DispatchGroup()
        group.enter()
        fetch("https://cip.cc") { [weak self] text in
            self?.domestic = Self.parseCip(text)
            group.leave()
        }
        group.enter()
        fetch("https://ip.im/info") { [weak self] text in
            self?.foreign = Self.parseIpIm(text)
            group.leave()
        }
        group.notify(queue: .main) { [weak self] in
            self?.inFlight = false
            self?.lastFetch = Date()
            completion()
        }
    }

    private func fetch(_ url: String, done: @escaping (String?) -> Void) {
        guard let url = URL(string: url) else { return done(nil) }
        session.dataTask(with: url) { data, _, _ in
            done(data.flatMap { String(data: $0, encoding: .utf8) })
        }.resume()
    }

    /// cip.cc 纯文本格式："IP\t: x.x.x.x" / "运营商\t: 移动"
    static func parseCip(_ text: String?) -> Result? {
        guard let fields = keyValues(text) else { return nil }
        guard let ip = fields["IP"] else { return nil }
        return Result(ip: ip, note: fields["运营商"])
    }

    /// ip.im/info 纯文本格式："Ip:x.x.x.x" / "Country:US"（前面有 ASCII art 横幅）
    static func parseIpIm(_ text: String?) -> Result? {
        guard let fields = keyValues(text) else { return nil }
        guard let ip = fields["Ip"] else { return nil }
        return Result(ip: ip, note: fields["Country"])
    }

    private static func keyValues(_ text: String?) -> [String: String]? {
        guard let text else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty, !value.isEmpty, fields[key] == nil {
                fields[key] = value
            }
        }
        return fields.isEmpty ? nil : fields
    }
}
