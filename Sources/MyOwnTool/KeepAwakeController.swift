import AppKit
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import StatsCore

/// 保持唤醒：阻止自动息屏与闲置休眠，可选合盖不休眠、定时关闭与低电量关闭。
///
/// 开关状态只在本次运行内有效，启动时总是关闭；定时时长每次开启都从「不限」起步，
/// 合盖与低电量两项是偏好，持久化保存。
/// 息屏与闲置休眠用公开的 IOPMAssertion，进程退出时系统自动回收；
/// 合盖不休眠写的是内核全局标记，进程退出不会回收，因此要记账并在下次启动时补撤。
@MainActor
final class KeepAwakeController {
    private static let lidKey = "KeepAwakePreventLidSleep"
    private static let batteryThresholdKey = "KeepAwakeBatteryThreshold"
    /// 置位后到撤销前为真；启动时仍为真说明上次没走到撤销（崩溃或被强杀）
    private static let lidHeldKey = "KeepAwakeLidSleepDisabled"
    /// 周期检查：低电量判定、睡眠后补判定时，以及重写可能被 powerd 覆盖的合盖标记
    private static let checkInterval: TimeInterval = 30

    /// 菜单栏外框对应的生效状态
    enum Indicator {
        case off
        case awake
        case awakeWithLid
    }

    /// 生效状态变化时回调，菜单栏据此改外框颜色
    var onIndicatorChanged: ((Indicator) -> Void)?

    var indicator: Indicator {
        guard isActive else { return .off }
        return preventsLidSleep && isLidAvailable ? .awakeWithLid : .awake
    }

    private(set) var isActive = false
    /// 本次开启的截止时间，nil 表示不限
    private(set) var deadline: Date?
    private(set) var durationMinutes: Int?
    /// 上一次是否因低电量自动结束；再次开启时清除，设置页据此解释开关为何弹回
    private(set) var stoppedForLowBattery = false

    private var assertionIDs: [IOPMAssertionID] = []
    private var checkTimer: Timer?
    private var deadlineTimer: Timer?

    var isLidAvailable: Bool { Clamshell.isAvailable }

    var preventsLidSleep: Bool {
        get { UserDefaults.standard.bool(forKey: Self.lidKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.lidKey)
            // 合盖不休眠只在保持唤醒期间起作用，打开它即视为要保持唤醒
            if newValue, !isActive {
                setActive(true)
            } else {
                syncLid()
                onIndicatorChanged?(indicator)
            }
        }
    }

    /// 低电量阈值，nil 表示不启用；未存值时取默认 20%
    var batteryThreshold: Int? {
        get {
            guard let stored = UserDefaults.standard.object(forKey: Self.batteryThresholdKey) as? Int else {
                return KeepAwakePolicy.defaultBatteryThreshold
            }
            return stored > 0 ? stored : nil
        }
        set {
            UserDefaults.standard.set(newValue ?? 0, forKey: Self.batteryThresholdKey)
            check()
        }
    }

    /// 上次运行若没撤掉合盖标记，启动时补撤，避免合盖从此不再休眠
    func start() {
        if UserDefaults.standard.bool(forKey: Self.lidHeldKey) {
            releaseLid()
        }
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        if active {
            guard createAssertions() else { return }
            isActive = true
            stoppedForLowBattery = false
            let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            timer.tolerance = 5
            RunLoop.main.add(timer, forMode: .common)
            checkTimer = timer
        } else {
            isActive = false
            releaseAssertions()
            checkTimer?.invalidate()
            checkTimer = nil
            setDuration(nil)
        }
        syncLid()
        onIndicatorChanged?(indicator)
        if active { check() }
    }

    /// 从此刻起计时；未开启时忽略，结束本次开启时清回不限
    func setDuration(_ minutes: Int?) {
        deadlineTimer?.invalidate()
        deadlineTimer = nil
        guard isActive, let minutes else {
            durationMinutes = nil
            deadline = nil
            return
        }
        durationMinutes = minutes
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        deadline = end
        // 定时器按单调时钟计数，睡眠期间不走；周期检查用墙钟兜底，唤醒后至多晚一个周期
        let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadlineTimer = timer
    }

    func stop() {
        setActive(false)
    }

    private func check() {
        guard isActive else { return }
        let power = PowerSource.current()
        if KeepAwakePolicy.shouldStopForBattery(onBattery: power.onBattery, percent: power.percent,
                                                threshold: batteryThreshold) {
            setActive(false)
            stoppedForLowBattery = true
            return
        }
        if KeepAwakePolicy.shouldStopForDeadline(now: Date(), deadline: deadline) {
            setActive(false)
            return
        }
        syncLid()
    }

    /// 需要时每次都重写标记：powerd 的状态翻转会清掉同一个位
    private func syncLid() {
        if isActive, preventsLidSleep, isLidAvailable {
            if Clamshell.setSleepDisabled(true) {
                UserDefaults.standard.set(true, forKey: Self.lidHeldKey)
            }
        } else if UserDefaults.standard.bool(forKey: Self.lidHeldKey) {
            releaseLid()
        }
    }

    /// 撤销后若盖子正合着，内核会立即按合盖重新判定并进入睡眠
    private func releaseLid() {
        Clamshell.setSleepDisabled(false)
        UserDefaults.standard.set(false, forKey: Self.lidHeldKey)
    }

    /// 防息屏本身就会阻止闲置休眠；再持一份系统断言，合盖后内屏熄灭时仍不进入闲置休眠
    private func createAssertions() -> Bool {
        let reason = "MyOwnTools 保持唤醒" as CFString
        for type in [kIOPMAssertPreventUserIdleDisplaySleep, kIOPMAssertPreventUserIdleSystemSleep] {
            var id = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(type as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn), reason, &id)
            guard result == kIOReturnSuccess else {
                NSLog("MyOwnTools: 创建电源断言 \(type) 失败：\(result)")
                releaseAssertions()
                return false
            }
            assertionIDs.append(id)
        }
        return true
    }

    private func releaseAssertions() {
        assertionIDs.forEach { IOPMAssertionRelease($0) }
        assertionIDs = []
    }
}

/// 当前供电来源与内置电池电量；台式机没有电池时 percent 为 nil
private enum PowerSource {
    static func current() -> (onBattery: Bool, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return (false, nil) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onBattery = providing == kIOPMBatteryPowerKey
        let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let percent = KeepAwakePolicy.batteryPercent(current: description[kIOPSCurrentCapacityKey] as? Int,
                                                         max: description[kIOPSMaxCapacityKey] as? Int)
            return (onBattery, percent)
        }
        return (onBattery, nil)
    }
}

/// 合盖休眠开关：IOPMrootDomain 的 `kPMSetClamshellSleepState` 外部方法。
/// 选择子定义在 SDK 的 IOPMLibDefs.h，普通用户即可调用，powerd 也用它在桌面模式下禁用合盖休眠；
/// 写入的是内核里与 powerd 共用的一个禁用位，不随本进程退出而撤销，重启后清零。
/// 打不开 rootDomain 连接时整个合盖功能降级为不可用。
private enum Clamshell {
    private static let connect: io_connect_t = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return IO_OBJECT_NULL }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = IO_OBJECT_NULL
        guard IOServiceOpen(service, mach_task_self_, 0, &connect) == KERN_SUCCESS else { return IO_OBJECT_NULL }
        return connect
    }()

    static var isAvailable: Bool { connect != IO_OBJECT_NULL }

    @discardableResult
    static func setSleepDisabled(_ disabled: Bool) -> Bool {
        guard isAvailable else { return false }
        var input: UInt64 = disabled ? 1 : 0
        let result = IOConnectCallScalarMethod(connect, UInt32(kPMSetClamshellSleepState), &input, 1, nil, nil)
        if result != KERN_SUCCESS {
            NSLog("MyOwnTools: 设置合盖休眠失败：\(result)")
        }
        return result == KERN_SUCCESS
    }
}
