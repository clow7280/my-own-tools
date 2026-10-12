import Foundation
import IOKit

/// 一次完整采样的结果快照
struct StatsSample {
    /// 累计采样序号，由 StatsMonitor 逐条递增分配；sparkline 用它把桶边界锚在绝对时间上，
    /// 不随窗口滑动或历史截断改变（见 SparklineDownsample）
    var sequence: Int = 0
    var cpuUsage: Double = 0        // 0~1
    var cpuECore: Double?           // E 核平均占用；无异构核信息（如 Intel）时为 nil
    var cpuPCore: Double?
    var loadAvg: [Double] = []      // 1/5/15 分钟平均负载
    var cpuTemp: Double?            // ℃，平均核心温度；SMC 不可用时为 nil
    var cpuTempMax: Double?         // 当前最高核心温度
    var gpuUsage: Double = 0        // 0~1
    var gpuTemp: Double?
    var gpuTempMax: Double?
    var ramUsage: Double = 0        // 0~1
    var ramUsed: Double = 0         // 字节
    var ramTotal: Double = 0
    var ramApp: Double = 0          // App 内存（匿名页 − 可清除页）
    var ramWired: Double = 0        // 联动内存
    var swapUsed: Double = 0        // 字节
    var diskRead: Double = 0        // 字节/秒
    var diskWrite: Double = 0
    var diskReadTotal: Double = 0   // 开机以来累计字节
    var diskWriteTotal: Double = 0
    var diskTemp: Double?           // ℃，SMC 硬盘（NAND）传感器
    var batteryTemp: Double?        // ℃，SMC 电池传感器平均
    var memoryTemp: Double?         // ℃，SMC 统一内存传感器平均
    var socTemp: Double?            // ℃，SMC SoC 封装传感器平均
    var netUp: Double = 0           // 字节/秒
    var netDown: Double = 0
}

/// 整机与分簇 CPU 使用率：host_statistics / host_processor_info 的 tick 计数两次采样做差分
final class CPUSampler {
    private var prev: host_cpu_load_info?
    private var prevCores: [[Double]] = []

    /// E 核数量（hw.perflevel1 = 效率簇）；单一核类型的机器上为 0。
    /// Apple Silicon 的逻辑核编号从 E 簇开始，用它切分 host_processor_info 的结果
    private let eCoreCount = sysctlInt("hw.perflevel1.logicalcpu") ?? 0

    func sample() -> Double? {
        var info = host_cpu_load_info()
        var size = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        defer { prev = info }
        guard let prev else { return nil }

        // cpu_ticks 顺序：USER / SYSTEM / IDLE / NICE；&- 防计数器回绕
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return (user + system + nice) / total
    }

    /// E/P 簇平均占用；无异构核或首拍无差分基准时为 nil
    func sampleClusters() -> (e: Double, p: Double)? {
        var coreCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard eCoreCount > 0,
              host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                  &coreCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }
        guard eCoreCount < Int(coreCount) else { return nil }

        // 每核 4 个 tick 计数（USER/SYSTEM/IDLE/NICE），取无符号差分
        var cores: [[Double]] = []
        cores.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let base = core * Int(CPU_STATE_MAX)
            cores.append((0..<4).map { Double(UInt32(bitPattern: info[base + $0])) })
        }
        let previous = prevCores
        prevCores = cores
        guard previous.count == cores.count else { return nil }

        func busyRatio(_ range: Range<Int>) -> Double? {
            var busy = 0.0, total = 0.0
            for i in range {
                let ticks = (0..<4).map { cores[i][$0] - previous[i][$0] }
                busy += ticks[0] + ticks[1] + ticks[3]
                total += ticks[0] + ticks[1] + ticks[2] + ticks[3]
            }
            guard total > 0 else { return nil }
            return min(max(busy / total, 0), 1)
        }
        guard let e = busyRatio(0..<eCoreCount),
              let p = busyRatio(eCoreCount..<cores.count) else { return nil }
        return (e, p)
    }

    /// 1/5/15 分钟平均负载
    static func loadAverages() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }
}

private func sysctlInt(_ name: String) -> Int? {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
    return Int(value)
}

/// 内存占用与明细：host_statistics64，口径与活动监视器一致（同 Stats）
final class MemorySampler {
    struct Breakdown {
        var used: Double        // 字节
        var usage: Double       // 0~1
        var app: Double         // App 内存 = 匿名页 − 可清除页
        var wired: Double       // 联动
        var swap: Double        // SWAP 已用
    }

    let total = Double(ProcessInfo.processInfo.physicalMemory)

    func sample() -> Breakdown? {
        var stats = vm_statistics64()
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let page = Double(vm_page_size)
        // used = 活跃 + 不活跃 + 投机 + 联动 + 压缩 − 可清除 − 文件缓存
        let used = (Double(stats.active_count) + Double(stats.inactive_count) + Double(stats.speculative_count)
                    + Double(stats.wire_count) + Double(stats.compressor_page_count)
                    - Double(stats.purgeable_count) - Double(stats.external_page_count)) * page
        guard used > 0 else { return nil }
        let app = max(Double(stats.internal_page_count) - Double(stats.purgeable_count), 0) * page
        return Breakdown(used: used, usage: min(used / total, 1), app: app,
                         wired: Double(stats.wire_count) * page, swap: Self.swapUsed())
    }

    private static func swapUsed() -> Double {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return Double(usage.xsu_used)
    }
}

/// GPU 使用率与温度：IOKit 枚举 IOAccelerator（Apple Silicon 上为 AGX）读 PerformanceStatistics
final class GPUSampler {
    func sample() -> (usage: Double?, temp: Double?) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == kIOReturnSuccess else {
            return (nil, nil)
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["PerformanceStatistics"] as? [String: Any] else { continue }

            guard let utilization = stats["Device Utilization %"] as? Int ?? stats["GPU Activity(%)"] as? Int else { continue }
            let temp = (stats["Temperature(C)"] as? Int).map(Double.init)
            return (Double(utilization) / 100, temp)
        }
        return (nil, nil)
    }
}

/// 内置磁盘读写：IOBlockStorageDriver 的 Statistics 累计字节两次差分。
/// 只统计物理互连位置为 Internal 的驱动器，找不到时退回统计全部。
final class DiskSampler {
    private var prev: (read: UInt64, write: UInt64, time: TimeInterval)?

    func sample() -> (read: Double, write: Double, readTotal: Double, writeTotal: Double) {
        guard let totals = Self.totalBytes() else { return (0, 0, 0, 0) }
        let now = ProcessInfo.processInfo.systemUptime
        defer { prev = (totals.read, totals.write, now) }
        guard let prev, now > prev.time,
              totals.read >= prev.read, totals.write >= prev.write else {
            return (0, 0, Double(totals.read), Double(totals.write))
        }
        let dt = now - prev.time
        return (Double(totals.read - prev.read) / dt, Double(totals.write - prev.write) / dt,
                Double(totals.read), Double(totals.write))
    }

    private static func totalBytes() -> (read: UInt64, write: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == kIOReturnSuccess else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var internalSum: (read: UInt64, write: UInt64)?
        var allSum: (read: UInt64, write: UInt64) = (0, 0)
        var found = false
        while true {
            let entry = IOIteratorNext(iterator)
            guard entry != 0 else { break }
            defer { IOObjectRelease(entry) }

            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }
            let read = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let write = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0

            found = true
            allSum.read &+= read
            allSum.write &+= write
            if isInternal(entry) {
                internalSum = ((internalSum?.read ?? 0) &+ read, (internalSum?.write ?? 0) &+ write)
            }
        }
        guard found else { return nil }
        return internalSum ?? allSum
    }

    /// 驱动器的父设备（IOBlockStorageDevice）在协议特征里声明物理互连位置
    private static func isInternal(_ driver: io_object_t) -> Bool {
        var parent: io_object_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        guard let raw = IORegistryEntryCreateCFProperty(parent, "Protocol Characteristics" as CFString,
                                                        kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let characteristics = raw as? [String: Any] else { return false }
        return (characteristics["Physical Interconnect Location"] as? String) == "Internal"
    }
}

/// 上传/下载网速：sysctl NET_RT_IFLIST2 读 64 位接口字节计数，两次采样差分。
/// 只统计 en* 物理接口（Wi-Fi/以太网），避免 utun 等虚拟接口重复计数。
final class NetworkSampler {
    private var prev: (up: UInt64, down: UInt64, time: TimeInterval)?

    func sample() -> (up: Double, down: Double) {
        guard let totals = Self.totalBytes() else { return (0, 0) }
        let now = ProcessInfo.processInfo.systemUptime
        defer { prev = (totals.up, totals.down, now) }
        guard let prev, now > prev.time,
              totals.up >= prev.up, totals.down >= prev.down else { return (0, 0) }
        let dt = now - prev.time
        return (Double(totals.up - prev.up) / dt, Double(totals.down - prev.down) / dt)
    }

    private static func totalBytes() -> (up: UInt64, down: UInt64)? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }

        var up: UInt64 = 0, down: UInt64 = 0
        var offset = 0
        while offset + MemoryLayout<if_msghdr>.size <= size {
            var header = if_msghdr()
            buffer.withUnsafeBytes { raw in
                _ = memcpy(&header, raw.baseAddress!.advanced(by: offset), MemoryLayout<if_msghdr>.size)
            }
            guard header.ifm_msglen > 0 else { break }

            if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= size {
                var header2 = if_msghdr2()
                buffer.withUnsafeBytes { raw in
                    _ = memcpy(&header2, raw.baseAddress!.advanced(by: offset), MemoryLayout<if_msghdr2>.size)
                }
                var name = [CChar](repeating: 0, count: Int(IFNAMSIZ) + 1)
                if if_indextoname(UInt32(header2.ifm_index), &name) != nil,
                   String(cString: name).hasPrefix("en") {
                    up &+= header2.ifm_data.ifi_obytes
                    down &+= header2.ifm_data.ifi_ibytes
                }
            }
            offset += Int(header.ifm_msglen)
        }
        return (up, down)
    }
}
