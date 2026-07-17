import AppKit

/// 系统状态监视器：后台队列每秒采样一次，主线程回调；保留最近 1 分钟历史。
/// 用 DispatchSourceTimer 而非 Timer，不受菜单/事件追踪 runloop mode 影响；系统睡眠时暂停。
final class StatsMonitor {
    /// 1 秒 × 60 条历史；弹窗 sparkline 显示完整 1 分钟窗口
    static let historyCapacity = 60
    static let sampleInterval: TimeInterval = 1

    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let gpu = GPUSampler()
    private let disk = DiskSampler()
    private let network = NetworkSampler()

    private let queue = DispatchQueue(label: "myowntool.stats", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var suspended = false

    // 以下仅在 queue 上访问：SMC 连接与懒发现的温度键
    private var smc: SMCReader?
    private var cpuTempKeys: [String]?
    private var gpuTempKeys: [String]?
    private var diskTempKeys: [String]?
    private var batteryTempKeys: [String]?

    /// 主线程访问：最近的采样历史（含最新一条）
    private(set) var history: [StatsSample] = []
    /// 主线程回调：每秒一次，带最新样本
    var onSample: ((StatsSample) -> Void)?

    init() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(pauseTimer), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(resumeTimer), name: NSWorkspace.didWakeNotification, object: nil)
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.sampleInterval, leeway: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        guard let timer else { return }
        if suspended {
            timer.resume()  // 取消/释放挂起状态的 source 会崩溃，先恢复
            suspended = false
        }
        timer.cancel()
        self.timer = nil
    }

    @objc private func pauseTimer() {
        guard let timer, !suspended else { return }
        timer.suspend()
        suspended = true
    }

    @objc private func resumeTimer() {
        guard let timer, suspended else { return }
        // 唤醒后清掉差分基准，避免把睡眠期间的累计量算成一秒内的速率
        queue.async { [weak self] in
            _ = self?.cpu.sample()
            _ = self?.cpu.sampleClusters()
            _ = self?.disk.sample()
            _ = self?.network.sample()
        }
        timer.resume()
        suspended = false
    }

    // MARK: - 采样（在 queue 上执行）

    private func tick() {
        var sample = StatsSample()
        if let usage = cpu.sample() { sample.cpuUsage = usage }
        if let clusters = cpu.sampleClusters() {
            sample.cpuECore = clusters.e
            sample.cpuPCore = clusters.p
        }
        sample.loadAvg = CPUSampler.loadAverages()
        if let mem = memory.sample() {
            sample.ramUsed = mem.used
            sample.ramUsage = mem.usage
            sample.ramApp = mem.app
            sample.ramWired = mem.wired
            sample.swapUsed = mem.swap
        }
        sample.ramTotal = memory.total
        let gpuResult = gpu.sample()
        if let usage = gpuResult.usage { sample.gpuUsage = usage }
        (sample.diskRead, sample.diskWrite, sample.diskReadTotal, sample.diskWriteTotal) = disk.sample()
        (sample.netUp, sample.netDown) = network.sample()

        // 温度：CPU 走 SMC（M5 键为 Tp**）；GPU 优先取 IOAccelerator 自带值，缺失时走 SMC Tg**；
        // 硬盘（NAND TH**）与电池（TB*T）用于弹窗温度卡和 RAM 柱边框
        setupSMCIfNeeded()
        if let smc {
            let cpuTemps = smc.temperatures(cpuTempKeys ?? [])
            if !cpuTemps.isEmpty {
                sample.cpuTemp = cpuTemps.reduce(0, +) / Double(cpuTemps.count)
                sample.cpuTempMax = cpuTemps.max()
            }
            let gpuTemps = smc.temperatures(gpuTempKeys ?? [])
            if !gpuTemps.isEmpty {
                sample.gpuTemp = gpuTemps.reduce(0, +) / Double(gpuTemps.count)
                sample.gpuTempMax = gpuTemps.max()
            } else if let temp = gpuResult.temp {
                sample.gpuTemp = temp
                sample.gpuTempMax = temp
            }
            sample.diskTemp = smc.averageTemperature(diskTempKeys ?? [])
            sample.batteryTemp = smc.averageTemperature(batteryTempKeys ?? [])
        } else if let temp = gpuResult.temp {
            sample.gpuTemp = temp
            sample.gpuTempMax = temp
        }

        DispatchQueue.main.async {
            self.history.append(sample)
            if self.history.count > Self.historyCapacity {
                self.history.removeFirst(self.history.count - Self.historyCapacity)
            }
            self.onSample?(sample)
        }
    }

    /// 首次采样时建立 SMC 连接并枚举温度键（一次性，约几十毫秒，在后台队列完成）
    private func setupSMCIfNeeded() {
        guard cpuTempKeys == nil else { return }
        smc = SMCReader()
        guard let smc else {
            cpuTempKeys = []
            gpuTempKeys = []
            diskTempKeys = []
            batteryTempKeys = []
            NSLog("MyOwnTools: SMC 连接失败，温度显示不可用")
            return
        }
        // Tp=P核 Te=E核 Tf=M3 系 CPU 簇；Tg=GPU；TH=硬盘/NAND；TB*T=电池。
        // 枚举过滤比按芯片代硬编码更通用；只枚举一次全部键
        let keys = smc.allKeys()
        func plausible(_ key: String) -> Bool {
            guard let v = smc.double(key) else { return false }
            return v > 1 && v < 125
        }
        let cpu = keys.filter { ["Tp", "Te", "Tf"].contains(where: $0.hasPrefix) && plausible($0) }
        let gpu = keys.filter { $0.hasPrefix("Tg") && plausible($0) }
        let disk = keys.filter { $0.hasPrefix("TH") && plausible($0) }
        let battery = keys.filter { $0.hasPrefix("TB") && $0.hasSuffix("T") && plausible($0) }
        cpuTempKeys = cpu
        gpuTempKeys = gpu
        diskTempKeys = disk
        batteryTempKeys = battery
        // 核心温度(CPU/GPU)驱动菜单栏边框分级,枚举不到才记一条便于排查机型差异,正常启动静默
        if cpu.isEmpty || gpu.isEmpty {
            NSLog("MyOwnTools: SMC 温度键发现异常 CPU=%d GPU=%d 硬盘=%d 电池=%d",
                  cpu.count, gpu.count, disk.count, battery.count)
        }
    }
}
