import Foundation

/// 命令行探针：`MyOwnTool --stats-probe`
/// 不启动 GUI，直接验证全部数据通路（CPU/GPU/RAM/网速/SMC 温度），打印结果后退出
enum StatsProbe {
    static func run() -> Never {
        print("== myowntool 系统状态探针 ==")
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let gpu = GPUSampler()
        let net = NetworkSampler()
        _ = cpu.sample()    // 差分类采样先建立基准
        _ = net.sample()

        if let smc = SMCReader() {
            let cpuKeys = smc.discoverTemperatureKeys(prefixes: ["Tp", "Te", "Tf"])
            let gpuKeys = smc.discoverTemperatureKeys(prefixes: ["Tg"])
            print("SMC CPU 温度键 (\(cpuKeys.count)): \(cpuKeys.joined(separator: " "))")
            print("SMC GPU 温度键 (\(gpuKeys.count)): \(gpuKeys.joined(separator: " "))")
            print("CPU 温度: " + (smc.averageTemperature(cpuKeys).map { String(format: "%.1f℃", $0) } ?? "不可用"))
            print("GPU 温度: " + (smc.averageTemperature(gpuKeys).map { String(format: "%.1f℃", $0) } ?? "不可用"))
        } else {
            print("SMC: 连接失败，温度不可用")
        }

        Thread.sleep(forTimeInterval: 1.5)

        print("CPU 使用率: " + (cpu.sample().map(StatsFormat.percent) ?? "不可用"))
        let gpuResult = gpu.sample()
        print("GPU 使用率: " + (gpuResult.usage.map(StatsFormat.percent) ?? "不可用")
              + "  (IOAccelerator 自带温度: " + (gpuResult.temp.map { String(format: "%.0f℃", $0) } ?? "无") + ")")
        if let (used, usage) = memory.sample() {
            print("内存: \(StatsFormat.gigabytes(used)) / \(StatsFormat.gigabytes(memory.total)) GB (\(StatsFormat.percent(usage)))")
        } else {
            print("内存: 不可用")
        }
        let (upSpeed, downSpeed) = net.sample()
        print("网速: ↑ \(StatsFormat.speed(upSpeed))/s  ↓ \(StatsFormat.speed(downSpeed))/s")

        if let route = RouteInfo.current() {
            print("出口接口: \(route.displayName ?? "?") (\(route.bsdName))  内网 IP: \(route.localIP ?? "—")")
        } else {
            print("出口接口: 无网络")
        }

        // 公网 IP 为异步请求，泵 runloop 等待完成（上限 12 秒）
        let fetcher = PublicIPFetcher()
        var fetchDone = false
        fetcher.refreshIfStale { fetchDone = true }
        let deadline = Date().addingTimeInterval(12)
        while !fetchDone && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        func text(_ r: PublicIPFetcher.Result?) -> String {
            r.map { "\($0.ip) · \($0.note ?? "?")" } ?? "获取失败"
        }
        print("公网 IP（国内 cip.cc）: \(text(fetcher.domestic))")
        print("公网 IP（国外 ip.im）: \(text(fetcher.foreign))")
        exit(0)
    }
}

/// AI 用量探针：`MyOwnTool --ai-probe`，验证 Claude/Codex 凭证读取与端点解析
enum AIProbe {
    static func run() -> Never {
        print("== myowntool AI 用量探针 ==")
        let group = DispatchGroup()
        // 凭证读取（含 Keychain）放后台，避免弹窗阻塞主线程，主线程照常泵 runloop
        group.enter()
        DispatchQueue.global().async {
            ClaudeUsageReader.fetch { print(format("Claude", $0)); group.leave() }
        }
        group.enter()
        DispatchQueue.global().async {
            CodexUsageReader.fetch { print(format("Codex", $0)); group.leave() }
        }
        let deadline = Date().addingTimeInterval(25)
        var done = false
        group.notify(queue: .main) { done = true }
        while !done && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        if !done { print("[超时：部分数据未返回，可能是 Keychain 授权未完成]") }
        exit(0)
    }

    private static func format(_ name: String, _ u: AIUsage) -> String {
        func pct(_ v: Double?) -> String { v.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
        var s = "\(name): 5h=\(pct(u.fiveHour))  7d=\(pct(u.sevenDay))  plan=\(u.plan ?? "?")"
        if let e = u.error { s += "  [\(e)]" }
        if !u.models.isEmpty {
            s += "\n  模型：" + u.models.map { "\($0.name) \(pct($0.percent))" }.joined(separator: "  ·  ")
        }
        if let r = u.fiveHourResetsAt ?? u.sevenDayResetsAt {
            s += "\n  重置：\(r)"
        }
        return s
    }
}
