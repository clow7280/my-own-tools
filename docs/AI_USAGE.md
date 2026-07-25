# AI 用量接入架构

本文定义 MyOwnTools 的 AI 用量数据模型、数据源降级顺序、安全边界和新增提供方流程。

当前实现以 CodexBar `cc8da27cec92029a6435bfee4a703a719290234e` 为研究基线，参考其 [provider 指南](https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/docs/provider.md)、[架构说明](https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/docs/architecture.md)、[刷新循环](https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/docs/refresh-loop.md)及 Claude、Codex、OpenCode Go 的实际 descriptor 和 fetcher。

CodexBar 的文档与当前代码在部分自动数据源顺序上存在差异，因此本项目以固定提交的代码和自身安全边界为准，而不是复制旧文档中的分支。

## 结构

AI 接入拆成独立的 `AIUsageCore` target，不依赖 AppKit。

```text
AIProviderRegistry
  └─ AIProviderDescriptor
       └─ AIUsageFetchPipeline
            ├─ availability
            ├─ fetch strategy 1
            ├─ typed fallback decision
            └─ fetch strategy N
                 ↓
          AIUsageFetchOutcome
                 ↓
       AIUsageMonitor → presentation → 菜单栏与弹窗
```

`AIProviderRegistry` 是提供方顺序、刷新策略和数据抓取管线的唯一核心清单，App、AI 探针和后台监视器共同使用它。

`AIUsageFetchStrategy` 是开放协议，每个数据源只负责可用性检测、一次抓取和明确的 fallback 判断；
管线同时传递 `.automatic` 或 `.userInitiated` 上下文，统一约束凭证交互。

`AIUsageSnapshot` 只保存成功数据，错误、尝试记录、数据源质量和刷新状态分别放在 `AIUsageFetchOutcome` 与 `AIProviderState` 中。

窗口使用开放字符串 ID，值显式区分 `.measured(0...1)`、`.notEnforced` 和 `.unavailable`，不再让 `nil` 同时表示限额取消、字段缺失和解析失败。

数据源质量分为服务端实时值 `live`、本机历史估算值 `estimated` 和离线旧快照 `cached`，UI 不应把后三者冒充实时值。

## 当前数据源

| 提供方 | 自动顺序 | 成功质量 | 凭证与数据 |
|---|---|---|---|
| Codex | OAuth → rollout | `live` → `cached` | 只读 `$CODEX_HOME/auth.json` 或 `~/.codex/auth.json`；离线读取最近会话末尾的 `rate_limits` |
| Claude | OAuth | `live` | 只读 Claude Code Keychain，结构无效时回退 `~/.claude/.credentials.json` |
| OpenCode Go | 本地 SQLite → Web | `estimated` → `live` | 只读 `~/.local/share/opencode/opencode.db`；本地不可用时导入浏览器 Cookie |

Codex OAuth 从 `config.toml` 严格解析 `chatgpt_base_url`：ChatGPT backend 调用 `wham/usage`，其他 HTTPS base 调用 `api/codex/usage`，认证请求始终只发送到配置中的精确 host。

每日 workspace 明细只为个人 Plus / Pro 的 ChatGPT backend 启用，属于可选增强；明细失败只写入 `partialFailures`，不会丢弃主窗口，也不会把团队聚合冒充个人周用量。

Codex rollout 最多检查 128 个文件、每个文件尾部 1 MiB 且总读取不超过 48 MiB；解析器逐行跳过残缺 UTF-8 与 malformed 新事件，并按内嵌事件时间跨文件选择最新有效快照。

Enterprise 的 `individual_limit` 会映射为稳定的月度额度扩展窗口；未知时长不会被猜成 5 小时或 7 天，而是保留准确时长单独展示。

`plan_type` 只出现在用量响应里，因此响应缺少该字段或降级到 rollout 快照时，改为在本机解码 `auth.json` 中 `id_token` 的 payload，取 `https://api.openai.com/auth` claim 下的 `chatgpt_plan_type` 作为订阅徽章。
解码不校验签名、不访问网络，除这一个套餐字符串外不读取其他 claim，也不写入日志。

CodexBar 当前自动链路是 [OAuth → CLI app-server](https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/Sources/CodexBarCore/Providers/Codex/CodexProviderDescriptor.swift)，但 app-server 的认证管理可能刷新并持久化用户凭证，因此本项目不在后台启动它，也不移植 CodexBar 的 refresh token 写回逻辑。

Claude OAuth 兼容 `five_hour`、`seven_day`、旧版顶层专属窗口和新版 `limits[]`。
`limits[]` 中 `kind` 为 `session` 和 `weekly_all` 的条目是 5 小时与 7 天窗口的候选值，`weekly_scoped` 仍按模型展开为专属窗口。

单个窗口的取值顺序为对象自身的 `utilization` 或 `used_percent`、`limits[]` 候选、`used_dollars ÷ limit_dollars`，`resets_at` 缺失时同样回退到候选条目。
服务端会间歇性把 `utilization` 写成 null，前一档取不到值不影响后两档兜底。

`five_hour` 显式缺失或为 null，且 `limits[]` 没有对应条目、周窗口又有数据时，5 小时限额记为取消。
对象存在却三档都取不到值时只把该窗口记为数据缺失，其余窗口照常展示；只有整份响应没有任何可识别窗口才判定为结构变化。

仅有 `extra_usage` 的消费限额账号映射为月度消费窗口；凭证会校验 `expiresAt`，成功的手动 Keychain
读取只缓存在当前进程，401 会使对应缓存失效。

Claude 401 不会触发伪刷新或写入凭证，而是提示用户自行运行 `claude auth login`。

Claude 后台刷新先读凭证文件，再做禁止 UI 的 Keychain 查询；用户手动刷新时优先读取 Keychain，
结构无效才回退凭证文件。

OpenCode Go 本地源按 CodexBar 的 [只读 SQLite 实现](https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/Sources/CodexBarCore/Providers/OpenCodeGo/OpenCodeGoLocalUsageReader.swift)聚合 5 小时、UTC 周和锚定月窗口，并沿用当前公开额度 `$12 / $30 / $60`，所以结果必须标记为估算。

OpenCode Web 源先解析工作区，再逐一读取 `/workspace/{id}/go`；工作区 GET 成功但缺少 ID 时会有界重试 POST。

用量解析同时覆盖 JSON、Seroval 的 `$R[n]=` hydration、嵌套 `window` 与 `used / limit` 结构；未知结构会返回 `schemaChanged`，不会借用相邻窗口字段拼成错误结果。

这里的 OpenCode 指 [OpenCode Go](https://github.com/steipete/CodexBar/blob/cc8da27cec92029a6435bfee4a703a719290234e/Sources/CodexBarCore/Providers/OpenCodeGo/OpenCodeGoUsageFetcher.swift)，
不能与 CodexBar 中标准 OpenCode 订阅提供方混为一谈；实现不会调用标准 OpenCode 的
`subscription.get` server function，也不会把其 quota 标记成 Go 用量。

## 失败与状态

管线记录每次 strategy 的可用性、类型和归一化失败类别，只有 strategy 明确允许时才进入下一数据源。

网络失败、限流、凭证缺失、认证失败、服务字段变化、本地数据失败、安全拒绝和取消各自具有稳定类型，UI 和探针不解析错误字符串来决定行为。

后台监视器按提供方 generation 丢弃过期完成回调；睡眠唤醒后绕过用户配置间隔，但仍遵守提供方的最小
轮询间隔，失败时保留最近成功快照。

刷新间隔按请求发起时刻计算并为定时器 leeway 留出余量，因此一次耗时数秒的拉取不会让下一个周期被
判成刚刷新过而跳过，自动刷新稳定保持在用户设置的间隔上。

自动与睡眠唤醒刷新禁止弹出钥匙串授权 UI；只有卡片手动刷新和显式 AI 探针使用
`.userInitiated`，允许 macOS 请求一次凭证访问授权。

健康计时器独立于网络刷新，失败先显示黄色警告，超过用户设置的数据过期阈值后转红，不需要等待下一次请求才更新状态。

`cached` 成功仍显示为降级警告，且不会用更旧的本地事件覆盖较新的实时快照；`estimated` 成功保留来源标签但不当作错误。

## 安全与隐私

认证请求使用 ephemeral `URLSession`，禁用 Cookie 存储和缓存，只允许 provider 声明的精确 HTTPS host，并拒绝所有重定向。

所有认证头在发送前拒绝 CR/LF，浏览器 Cookie 进一步限制为 RFC 6265 的安全字符，并只接受 `opencode.ai` 与 `.opencode.ai` 的精确域。

OpenCode 会先检查 Cookie 数据库，再按浏览器分批访问 Safe Storage；不同 profile 的有界候选逐一用真实用量请求验证，只有成功候选才进入进程内缓存。

后台凭证读取同时设置禁止交互的 `LAContext` 与旧版 Keychain UI-fail 策略。OpenCode 先尝试明文
Cookie 与旧版固定密钥，确有需要时才读取 Safe Storage；手动刷新可以弹出系统授权，自动刷新只能
使用已经可无交互取得或本进程内缓存的凭证。

Cookie、token、工作区 ID、账户 ID、原始响应和浏览器绝对路径不得写入日志、探针、UserDefaults 或文件。

应用不会修改 Codex、Claude、OpenCode 的凭证、配置或数据库。

## 新增提供方

新增接入时按以下顺序完成：

1. 在 `Sources/AIUsageCore/Providers/` 新增 parser、credential reader 和一个或多个 `AIUsageFetchStrategy`。
2. 明确每个窗口的单位、归一化方式、失败语义、刷新下限、执行线程、凭证交互和睡眠恢复行为。
3. 用 `AIProviderDescriptor` 声明有序策略，并加入 `AIProviderRegistry`。
4. 在 `AIProviderPresentationRegistry` 增加名称、窗口标题、颜色和菜单栏槽位；不得把 AppKit 类型放入核心 target。
5. 为 parser、schema 漂移和 fallback 判断增加 `AIUsageCoreChecks` fixture，确保校验不读取真实凭证也不访问网络。
6. 更新 [README](../README.md)；如改动颜色、尺寸或视觉语义，先更新 [DESIGN](../DESIGN.md)。

验证命令为：

```sh
swift build
swift run AIUsageCoreChecks
swift run MyOwnTools --ai-probe
```

前两项不访问用户凭证或网络，AI 探针只用于相关任务，并且只能输出归一化窗口、数据源类别和安全错误摘要。
