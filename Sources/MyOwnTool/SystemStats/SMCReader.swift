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

    /// 按前缀发现温度键：枚举全部键后过滤前缀，并要求首次读数在合理量程内。
    /// 不同代芯片的键名不同（M5 的 CPU 是 Tp00/Tp04/…），枚举比硬编码更通用。
    func discoverTemperatureKeys(prefixes: [String]) -> [String] {
        allKeys().filter { key in
            guard prefixes.contains(where: { key.hasPrefix($0) }) else { return false }
            guard let value = double(key) else { return false }
            return value > 1 && value < 125
        }
    }

    /// 一组键的即时读数（逐键读取，忽略掉线或失真的值）
    func temperatures(_ keys: [String]) -> [Double] {
        keys.compactMap { key in
            guard let v = double(key), v > 1, v < 125 else { return nil }
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
