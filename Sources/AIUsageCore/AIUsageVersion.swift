/// 版本号在 AIUsageCore 侧的唯一来源。请求头里的版本串原本散落在各 provider 中，
/// 发版时逐处手改容易漏掉某个端点，让同一个版本对外呈现两个标识。
///
/// 设置页页脚读 Info.plist 失败时的兜底值已改为引用 `short`，不再是需要手工同步的副本。
/// 剩下两处在 Swift 之外，改版时仍需一并同步：
/// - `README.md` 开头声明的当前版本
/// - `scripts/make-app.sh` 中 Info.plist 的 `CFBundleShortVersionString`
public enum AIUsageVersion {
    /// 与 git 标签、`CFBundleShortVersionString` 共用同一个字符串，一律不带 `v` 前缀。
    public static let short = "0.3.1"

    /// 认证请求统一使用的产品标识；由短串拼出，避免版本号出现第二处字面量。
    public static let userAgent = "MyOwnTools/" + AIUsageVersion.short
}
