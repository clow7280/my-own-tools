# AGENTS.md

## 项目概览

MyOwnTools 是面向 macOS 13 及以上版本的个人菜单栏应用。
项目使用 Swift 5.9、Swift Package Manager 和 AppKit，不依赖第三方库，不使用 Storyboard 或 XIB。
应用以 accessory 模式运行，提供 Shift 拖拽窗口吸附，以及 CPU、GPU、内存、网络和 AI 用量展示。

## 目录结构

```text
.
├── Sources/
│   └── MyOwnTool/
│       └── SystemStats/   系统采样、AI 用量和状态 UI
├── Resources/             应用资源
└── scripts/               图标生成与 app 打包脚本
```

根目录的 `README.md` 面向用户，`DESIGN.md` 定义系统状态 UI 规范，`Package.swift` 定义构建目标。

## 构建与验证

```sh
swift build
swift run MyOwnTools
swift run MyOwnTools --stats-probe
swift run MyOwnTools --ai-probe
./scripts/make-app.sh
```

- 所有改动完成后至少运行 `swift build` 进行验证。
- 修改 release、打包或签名逻辑时，额外运行 `swift build -c release` 或打包脚本。
- 系统状态探针用于验证采样、温度、路由和公网 IP；AI 探针用于验证本机凭证读取与远端接口。
- AI 探针会访问用户凭证和远端服务，仅在相关任务中运行，禁止输出或保存 token 与敏感响应。
- 仓库没有 XCTest target；菜单栏、辅助功能、多显示器和失焦交互需要在图形会话中手工验证。
- 默认打包证书为 `MyOwnToolSigning`；本机缺少证书时可用 `CODESIGN_IDENTITY=-` 临时验证打包。

## 架构与边界

- `AppDelegate` 负责模块装配；系统采样和 AI 请求在后台执行，所有 AppKit 更新回到主线程。
- 全局事件监听保持只读，不改成会修改事件流的主动式 `CGEventTap`。
- Accessibility 调用保留短超时、自身窗口排除和“尺寸 → 位置 → 尺寸”的窗口设置顺序。
- 分区基于 `NSScreen.visibleFrame`，必须避开菜单栏和 Dock，并正确转换 Cocoa 与 AX 坐标。
- 用户布局位于 `~/.config/myowntool/layouts.json`；读取失败时回退默认值，不覆盖已有配置。
- 差分采样器在系统唤醒后重建基准；硬件数据不可用时应降级显示，不得导致应用退出。
- SMC 和 IOAccelerator 字段随机型与系统变化，不硬编码单一设备假设。
- AI 用量统一为 `0...1`；菜单栏双层环外环为 5 小时窗口、内环为 7 天窗口，
  5 小时限额取消（无 5h 但有 7d 数据）时外环画虚点圆。
- Claude 与 Codex 接口并非稳定公共契约；改动端点或解析时保留错误状态和 Codex 离线回退。
- 登录项仅支持 `.app`；不要随意修改 bundle ID 和签名逻辑，以免破坏辅助功能授权与登录项。
- 保持 macOS 13 最低版本和零第三方依赖，除非任务明确要求变更。
- 不修改用户配置、凭证、签名证书或与任务无关的工作区改动。

## 修改要求

- 修改前阅读目标模块源码与 `README.md`；涉及系统状态视觉时同时阅读 `DESIGN.md`。
- 调整系统状态的颜色、尺寸或视觉语义时，先更新 `DESIGN.md`，再同步代码。
- 图标以生成脚本为源；修改构图后重新生成 `Resources/AppIcon.icns`。
- 新增采样时明确单位、失败语义、执行线程、刷新频率和睡眠恢复行为。
- 新增 UI 时沿用程序化 AppKit 和动态系统色，检查浅色、深色、菜单栏空间与失焦行为。
- 新增用户可见功能、配置、权限或运行步骤时同步更新 `README.md`。
- 无法执行依赖硬件、授权、Keychain 或网络的验证时，在交付说明中明确未验证项。

## Markdown 文档写作

- 仅在必要时加粗，不使用 `- **XX**: XXX` 式列表。
- 中文与 ASCII 字符之间加空格，与中文标点之间不加空格。
- 减少括号、重复章节和跨文档重复；引用时使用项目根目录相对链接。
- `docs/` 使用 Markdown，配图放在文档同级的 `figs/`。
- 段落单句换行，优先用段落和多级列表表达结构。

## Git 提交规范

标题格式为 `<type>(<scope>): <desc>`，未明确处遵循 Conventional Commits v1.0.0。

- type 仅使用 `NEW`、`FIX`、`REF`，分别表示新增、修复和重构。
- scope 对应根目录一级目录；根目录或无法归类时用 `misc`，大型联动改动用 `*`。
- desc 使用简短中文，中文与英文或数字之间加空格。
- 标题建议不超过 100 字符，强制不超过 120 字符，中文按 2 字符计算。
