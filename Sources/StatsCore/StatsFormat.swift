import Foundation

/// 数值格式化（菜单栏与弹窗共用）
public enum StatsFormat {
    /// 菜单栏网速 → (数字, 单位)：数字含小数点最多 3 字符，单位 B/K/M/G 自动切换（1000 进制），
    /// 1000 以下显示整数字节，其余各档小于 9.95 时保留一位小数
    public static func menuSpeed(_ bps: Double) -> (number: String, unit: String) {
        var value = max(bps, 0)
        // B 档一直用到 999：999B 与 999K 等宽不会额外撑开菜单栏，
        // 而过早进位会把 10~49 B/s 显示成 0.0K，非零速率的读数被抹成 0；
        // 阈值取 999.5 与下面各档一致，避免四舍五入进位到 4 个数字字符
        if value < 999.5 { return (String(format: "%.0f", value), "B") }
        for unit in ["K", "M", "G"] {
            value /= 1000
            if value < 999.5 || unit == "G" {
                let number = value < 9.95 ? String(format: "%.1f", value)
                                          : String(format: "%.0f", value)
                return (number, unit)
            }
        }
        return ("0", "B")
    }

    /// 字节/秒 → 紧凑速率文本（如 "312M"、"1.2M"、"999B"）：
    /// 沿用菜单栏网速的 3 字符数字加单位规则，1000 以下保留整数字节，
    /// 供 sparkline 右侧刻度列这类窄列使用
    public static func compactSpeed(_ bps: Double) -> String {
        let (number, unit) = menuSpeed(bps)
        return number + unit
    }

    /// 字节/秒 → MB/s 数字文本（单位由 UI 单独绘制）
    public static func mbps(_ bps: Double) -> String {
        let value = bps / 1_000_000
        if value < 9.995 { return String(format: "%.2f", value) }
        if value < 99.95 { return String(format: "%.1f", value) }
        return String(format: "%.0f", value)
    }

    /// 字节 → 数据总量文本（累计读写：MB/GB/TB 自动，1000 进制）
    public static func dataVolume(_ bytes: Double) -> String {
        switch bytes {
        case ..<1e9: return String(format: "%.0f MB", bytes / 1e6)
        case ..<1e12: return String(format: "%.1f GB", bytes / 1e9)
        default: return String(format: "%.1f TB", bytes / 1e12)
        }
    }

    /// 0~1 → "34%"
    public static func percent(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0), 1) * 100)
    }

    /// 字节 → 二进制 GB（与活动监视器一致）
    public static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f", bytes / 1_073_741_824)
    }
}
