import Foundation
import IOKit

/// AppleSMC 只读客户端，用于读取温度传感器。
/// 结构体布局是 AppleSMC 内核驱动约定的固定格式（未文档化），参考 exelban/stats（MIT）。
/// 不做任何写入（风扇控制等需要 root 的能力一概不碰）。
final class SMCReader {
    /// 与内核交互的固定结构，字段顺序与大小不可改动
    private struct KeyData {
        struct Vers {
            var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
            var release: UInt16 = 0
        }
        struct PLimit {
            var version: UInt16 = 0, length: UInt16 = 0
            var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
        }
        struct KeyInfo {
            var dataSize: UInt32 = 0
            var dataType: UInt32 = 0
            var dataAttributes: UInt8 = 0
        }

        var key: UInt32 = 0
        var vers = Vers()
        var pLimitData = PLimit()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
             0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }

    private enum Selector: UInt8 {
        case kernelIndex = 2
        case readBytes = 5
        case readIndex = 8
        case readKeyInfo = 9
    }

    private var conn: io_connect_t = 0

    init?() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iterator) == kIOReturnSuccess else {
            return nil
        }
        let device = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        guard device != 0 else { return nil }
        defer { IOObjectRelease(device) }
        guard IOServiceOpen(device, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOServiceClose(conn)
    }

    // MARK: - 读取

    /// 读取单个键并按数据类型解码为 Double（覆盖温度常见的 flt / sp78 / ui8-32）
    func double(_ key: String) -> Double? {
        guard let (type, bytes) = readBytes(key) else { return nil }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let raw = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: raw))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        case "ui8 ":
            return bytes.first.map(Double.init)
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        default:
            return nil
        }
    }

    /// 枚举 SMC 全部键名（约上千个，仅在发现传感器时调用一次）
    func allKeys() -> [String] {
        guard let count = double("#KEY"), count > 0 else { return [] }
        var list: [String] = []
        list.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            var input = KeyData()
            var output = KeyData()
            input.data8 = Selector.readIndex.rawValue
            input.data32 = UInt32(i)
            guard call(&input, &output) == kIOReturnSuccess else { continue }
            list.append(Self.fourCC(output.key))
        }
        return list
    }

    /// 温度键的分类结果；机型没有某类传感器时对应字段为空数组
    struct TemperatureKeys {
        var cpu: [String] = []
        var gpu: [String] = []
        var disk: [String] = []
        var battery: [String] = []
    }

    /// 分组条件：一组前缀，外加可选后缀。
    /// 电池温度键形如 TB*T，同前缀下还有电压电流键，只按前缀会把它们一起收进来
    private struct TemperatureGroup {
        let prefixes: [String]
        var suffix: String? = nil
        let field: WritableKeyPath<TemperatureKeys, [String]>

        func matches(_ key: String) -> Bool {
            guard prefixes.contains(where: key.hasPrefix) else { return false }
            guard let suffix else { return true }
            return key.hasSuffix(suffix)
        }
    }

    /// Tp=P核 Te=E核 Tf=M3 系 CPU 簇；Tg=GPU；TH=硬盘/NAND；TB*T=电池。
    /// 各代芯片的键名不同（M5 的 CPU 是 Tp00/Tp04/…），枚举过滤比按芯片代硬编码键名通用
    private static let temperatureGroups: [TemperatureGroup] = [
        TemperatureGroup(prefixes: ["Tp", "Te", "Tf"], field: \TemperatureKeys.cpu),
        TemperatureGroup(prefixes: ["Tg"], field: \TemperatureKeys.gpu),
        TemperatureGroup(prefixes: ["TH"], field: \TemperatureKeys.disk),
        TemperatureGroup(prefixes: ["TB"], suffix: "T", field: \TemperatureKeys.battery),
    ]

    /// 温度读数的合理量程，开区间两端都不取：下界滤掉未接传感器恒定返回的 0，
    /// 上界滤掉明显失真的读数。发现键与逐次读取共用同一判据，
    /// 否则探针与运行时会对同一机型给出不同结论，而这种漂移不产生任何报错
    private static let plausibleCelsius = (lower: 1.0, upper: 125.0)

    private static func isPlausible(_ celsius: Double) -> Bool {
        celsius > plausibleCelsius.lower && celsius < plausibleCelsius.upper
    }

    /// 发现温度键：枚举一次全部键并同时分出各组，只对命中前缀的键补一次读取确认量程。
    /// 每组各自枚举会把上千个键重复走一遍，调用方一律共用这一次分类
    func discoverTemperatureKeys() -> TemperatureKeys {
        var result = TemperatureKeys()
        for key in allKeys() {
            let hits = Self.temperatureGroups.filter { $0.matches(key) }
            guard !hits.isEmpty, let value = double(key), Self.isPlausible(value) else { continue }
            for group in hits { result[keyPath: group.field].append(key) }
        }
        return result
    }

    /// 一组键的即时读数（逐键读取，忽略掉线或失真的值）
    func temperatures(_ keys: [String]) -> [Double] {
        keys.compactMap { key in
            guard let v = double(key), Self.isPlausible(v) else { return nil }
            return v
        }
    }

    /// 一组键的平均温度
    func averageTemperature(_ keys: [String]) -> Double? {
        let values = temperatures(keys)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    // MARK: - 内部

    private func readBytes(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard key.utf8.count == 4 else { return nil }
        var input = KeyData()
        var output = KeyData()
        input.key = key.utf8.reduce(0) { $0 << 8 | UInt32($1) }

        // 第一步：取键的数据类型与长度
        input.data8 = Selector.readKeyInfo.rawValue
        guard call(&input, &output) == kIOReturnSuccess else { return nil }
        let dataSize = output.keyInfo.dataSize
        let dataType = Self.fourCC(output.keyInfo.dataType)
        guard dataSize > 0 else { return nil }

        // 第二步：读字节
        input.keyInfo.dataSize = dataSize
        input.data8 = Selector.readBytes.rawValue
        guard call(&input, &output) == kIOReturnSuccess else { return nil }

        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(dataSize, 32)))) }
        return (dataType, bytes)
    }

    private func call(_ input: inout KeyData, _ output: inout KeyData) -> kern_return_t {
        let inputSize = MemoryLayout<KeyData>.stride
        var outputSize = MemoryLayout<KeyData>.stride
        return IOConnectCallStructMethod(conn, UInt32(Selector.kernelIndex.rawValue), &input, inputSize, &output, &outputSize)
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }
}
