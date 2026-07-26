/// 版本号在 AIUsageCore 侧的唯一来源。请求头里的版本串原本散落在各 provider 中，
/// 发版时逐处手改容易漏掉某个端点，让同一个版本对外呈现两个标识。
///
/// 版本号还存在于本 target 之外，改版时需要一并同步：
/// - `README.md` 开头声明的当前版本
/// - `scripts/make-app.sh` 中 Info.plist 的 `CFBundleShortVersionString`
/// - `SystemStats/StatsPages.swift` 里读取 Info.plist 失败时的兜底值
public enum AIUsageVersion {
    /// 与 git 标签、`CFBundleShortVersionString` 共用同一个字符串，一律不带 `v` 前缀。
    public static let short = "0.2"

    /// 认证请求统一使用的产品标识；由短串拼出，避免版本号出现第二处字面量。
    public static let userAgent = "MyOwnTools/" + AIUsageVersion.short
}
