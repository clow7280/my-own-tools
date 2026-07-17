import Foundation

/// 命令行探针：`MyOwnTools --stats-probe`
/// 不启动 GUI，直接验证全部数据通路（CPU/GPU/RAM/网速/SMC 温度），打印结果后退出
enum StatsProbe {
    static func run() -> Never {
        print("== MyOwnTools 系统状态探针 ==")
        let cpu = CPUSampler()
        let memory = MemorySampler()
        let gpu = GPUSampler()
        let disk = DiskSampler()
        let net = NetworkSampler()
        _ = cpu.sample()    // 差分类采样先建立基准
        _ = cpu.sampleClusters()
        _ = disk.sample()
        _ = net.sample()

        if let smc = SMCReader() {
            let cpuKeys = smc.discoverTemperatureKeys(prefixes: ["Tp", "Te", "Tf"])
            let gpuKeys = smc.discoverTemperatureKeys(prefixes: ["Tg"])
            let diskKeys = smc.discoverTemperatureKeys(prefixes: ["TH"])
            let batteryKeys = smc.discoverTemperatureKeys(prefixes: ["TB"]).filter { $0.hasSuffix("T") }
            print("SMC CPU 温度键 (\(cpuKeys.count)): \(cpuKeys.joined(separator: " "))")
            print("SMC GPU 温度键 (\(gpuKeys.count)): \(gpuKeys.joined(separator: " "))")
            print("SMC 硬盘温度键 (\(diskKeys.count)): \(diskKeys.joined(separator: " "))")
            print("SMC 电池温度键 (\(batteryKeys.count)): \(batteryKeys.joined(separator: " "))")
            func stats(_ keys: [String]) -> String {
                let values = smc.temperatures(keys)
                guard !values.isEmpty else { return "不可用" }
                let avg = values.reduce(0, +) / Double(values.count)
                return String(format: "平均 %.1f℃  峰值 %.1f℃", avg, values.max()!)
            }
            print("CPU 温度: " + stats(cpuKeys))
            print("GPU 温度: " + stats(gpuKeys))
            print("硬盘温度: " + stats(diskKeys))
            print("电池温度: " + stats(batteryKeys))
        } else {
            print("SMC: 连接失败，温度不可用")
        }

        Thread.sleep(forTimeInterval: 1.5)

        print("CPU 使用率: " + (cpu.sample().map(StatsFormat.percent) ?? "不可用"))
        if let clusters = cpu.sampleClusters() {
            print("CPU 簇: E 核 \(StatsFormat.percent(clusters.e))  P 核 \(StatsFormat.percent(clusters.p))")
        } else {
            print("CPU 簇: 不可用（无异构核信息）")
        }
        let loads = CPUSampler.loadAverages()
        if loads.count == 3 {
            print(String(format: "负载: %.2f / %.2f / %.2f", loads[0], loads[1], loads[2]))
        }
        let gpuResult = gpu.sample()
        print("GPU 使用率: " + (gpuResult.usage.map(StatsFormat.percent) ?? "不可用")
              + "  (IOAccelerator 自带温度: " + (gpuResult.temp.map { String(format: "%.0f℃", $0) } ?? "无") + ")")
        if let mem = memory.sample() {
            print("内存: \(StatsFormat.gigabytes(mem.used)) / \(StatsFormat.gigabytes(memory.total)) GB (\(StatsFormat.percent(mem.usage)))"
                  + "  App \(StatsFormat.gigabytes(mem.app)) GB  联动 \(StatsFormat.gigabytes(mem.wired)) GB  SWAP \(StatsFormat.gigabytes(mem.swap)) GB")
        } else {
            print("内存: 不可用")
        }
        let io = disk.sample()
        print("磁盘: 读 \(StatsFormat.mbps(io.read)) MB/s  写 \(StatsFormat.mbps(io.write)) MB/s"
              + "  累计读 \(StatsFormat.dataVolume(io.readTotal))  累计写 \(StatsFormat.dataVolume(io.writeTotal))")
        let (upSpeed, downSpeed) = net.sample()
        let up = StatsFormat.menuSpeed(upSpeed)
        let down = StatsFormat.menuSpeed(downSpeed)
        print("网速: ↑ \(up.number)\(up.unit)/s  ↓ \(down.number)\(down.unit)/s")

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
        let ip = fetcher.current.map { "\($0.ip) · \($0.note ?? "?")" } ?? "获取失败"
        print("公网 IP（cip.cc）: \(ip)")
        exit(0)
    }
}

/// AI 用量探针：`MyOwnTools --ai-probe`，验证 Claude/Codex 凭证读取与端点解析
enum AIProbe {
    static func run() -> Never {
        print("== MyOwnTools AI 用量探针 ==")
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
