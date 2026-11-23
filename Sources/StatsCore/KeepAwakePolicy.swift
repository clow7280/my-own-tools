import Foundation

/// 保持唤醒的自动结束判定：定时到点或电池电量过低时结束本次保持唤醒。
public enum KeepAwakePolicy {
    /// 设置页「低电量时关闭」的可选阈值（百分比），nil 表示不启用
    public static let batteryThresholds: [Int?] = [nil, 10, 20, 30, 50]
    public static let defaultBatteryThreshold = 20

    /// 设置页「定时关闭」的可选时长（分钟），nil 表示不限
    public static let durations: [Int?] = [nil, 30, 60, 120, 240, 480]

    /// 由 IOPowerSources 的当前容量与最大容量换算电量百分比，数据异常时返回 nil
    public static func batteryPercent(current: Int?, max: Int?) -> Int? {
        guard let current, let max, max > 0, current >= 0 else { return nil }
        return min(100, Int((Double(current) * 100 / Double(max)).rounded()))
    }

    /// 只在使用电池且电量严格低于阈值时结束；接电源、未启用阈值或读不到电量时不结束
    public static func shouldStopForBattery(onBattery: Bool, percent: Int?, threshold: Int?) -> Bool {
        guard onBattery, let percent, let threshold else { return false }
        return percent < threshold
    }

    /// 到点判定。截止时间用墙钟而非定时器计数，睡眠期间跨过的时间同样算数
    public static func shouldStopForDeadline(now: Date, deadline: Date?) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }
}
