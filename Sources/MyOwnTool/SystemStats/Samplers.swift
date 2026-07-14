import Foundation
import IOKit

/// 一次完整采样的结果快照
struct StatsSample {
    var cpuUsage: Double = 0        // 0~1
    var cpuTemp: Double?            // ℃，SMC 不可用时为 nil
    var gpuUsage: Double = 0        // 0~1
    var gpuTemp: Double?
    var ramUsage: Double = 0        // 0~1
    var ramUsed: Double = 0         // 字节
    var ramTotal: Double = 0
    var netUp: Double = 0           // 字节/秒
    var netDown: Double = 0
}

/// 数值格式化（菜单栏与弹窗共用）
enum StatsFormat {
    /// 字节/秒 → 紧凑文本（K/M/G 为 1000 进制的字节单位）
    static func speed(_ bps: Double) -> String {
        let kb = bps / 1000
        switch kb {
        case ..<1000: return String(format: "%.0fK", kb)
        case ..<10_000: return String(format: "%.1fM", kb / 1000)
        case ..<1_000_000: return String(format: "%.0fM", kb / 1000)
        default: return String(format: "%.1fG", kb / 1_000_000)
        }
    }

    /// 0~1 → "34%"
    static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0), 1) * 100)
    }

    /// 字节 → 二进制 GB（与活动监视器一致）
    static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f", bytes / 1_073_741_824)
    }
}

/// 整机 CPU 使用率：host_statistics 的 tick 计数两次采样做差分
final class CPUSampler {
    private var prev: host_cpu_load_info?

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
}

/// 内存占用：host_statistics64，口径与活动监视器一致（同 Stats）
final class MemorySampler {
    let total = Double(ProcessInfo.processInfo.physicalMemory)

    func sample() -> (used: Double, usage: Double)? {
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
        return (used, min(used / total, 1))
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
