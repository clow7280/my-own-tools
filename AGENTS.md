# AGENTS.md

## 项目概览

MyOwnTools 是面向 macOS 15 及以上版本的个人菜单栏应用。
项目使用 Swift 5.9、Swift Package Manager 和 AppKit，不依赖第三方库，不使用 Storyboard 或 XIB。
应用以 accessory 模式运行，提供 Shift 拖拽窗口吸附，以及 CPU、GPU、内存和网络状态展示。

## 目录结构

```text
.
├── Sources/
│   ├── StatsCore/         系统状态与布局的可测纯逻辑，不依赖 AppKit
│   └── MyOwnTool/
│       └── SystemStats/   系统采样和状态 UI
├── Tests/
│   └── StatsCoreChecks/   StatsCore 的离线校验可执行目标
├── Resources/             应用资源
├── docs/                  架构说明
└── scripts/               图标生成与 app 打包脚本
```

根目录的 `README.md` 面向用户，`DESIGN.md` 定义菜单栏、弹窗与编辑覆盖层的视觉规范，
`Package.swift` 定义构建目标。

## 构建与验证

```sh
swift build
swift run StatsCoreChecks
swift run MyOwnTools
swift run MyOwnTools --stats-probe
./scripts/make-app.sh
```

- 所有改动完成后至少运行 `swift build` 进行验证。
- 改动 `StatsCore` 或其校验时，额外运行 `swift run StatsCoreChecks`。
- 修改 release、打包或签名逻辑时，额外运行 `swift build -c release` 或打包脚本。
- 系统状态探针用于验证采样、温度、路由和公网 IP。
- 仓库没有 XCTest target，自动化校验由 `StatsCoreChecks` 可执行目标承载。
  它覆盖 `StatsCore` 的数值格式化、sparkline 分桶与量程、
  温度档位与布局数值判定这类纯逻辑边界。
  它不读取真实凭证，也不访问网络；依赖 AppKit 的部分不进校验目标，只能手工验证。
- 菜单栏、辅助功能、多显示器和失焦交互需要在图形会话中手工验证。
- 默认打包证书为 `MyOwnToolSigning`；本机缺少证书时可用 `CODESIGN_IDENTITY=-` 临时验证打包。
- `MyOwnToolSigning` 是自签名证书，未被信任，`security find-identity -v` 只列有效身份，
  会显示 0 个身份而隐藏它；用不带 `-v` 的 `security find-identity` 才能确认它是否存在。
  签名只需私钥和证书、不要求链路受信，所以 `codesign --sign MyOwnToolSigning` 仍可正常签名，
  不要因为 `-v` 列不出就误判证书丢失而回退 ad-hoc。
- 替换已安装的 `.app` 前确认新包沿用 `MyOwnToolSigning` 与 `com.clow.myowntools`；
  改用 ad-hoc 或其他身份会改变签名，令系统按新应用对待并作废已有辅助功能授权。

## 架构与边界

- `AppDelegate` 负责模块装配；系统采样在后台执行，所有 AppKit 更新回到主线程。
- 全局事件监听保持只读，不改成会修改事件流的主动式 `CGEventTap`。
- Accessibility 调用保留短超时、自身窗口排除和“尺寸 → 位置 → 尺寸”的窗口设置顺序。
- 分区基于 `NSScreen.visibleFrame`，必须避开菜单栏和 Dock，并正确转换 Cocoa 与 AX 坐标。
- 用户布局位于 `~/.config/myowntool/layouts.json`；读取失败或分区数值非法时回退默认值。
  覆盖用户配置的入口只有分割线编辑写回一处，写盘前先过读取时的同一套数值校验；
  不要新增其他写回路径。
- Shift 拖动覆盖层同时提供配置分区、全屏和专注目标；
  全屏只填满 `visibleFrame`，专注保留并夹取原尺寸后居中，不使用原生全屏空间。
- 分割线编辑器的移动、新增与删除都必须保持矩形分区合法且不制造重叠或空洞；
  可离线验证的分割与合并逻辑放在 `StatsCore` 并补断言。
- 差分采样器在系统唤醒后重建基准；硬件数据不可用时应降级显示，不得导致应用退出。
- SMC 和 IOAccelerator 字段随机型与系统变化，不硬编码单一设备假设。
- `StatsCore` 只放能离线校验的纯逻辑，不含 AppKit 视图与绘制；
  新增判定优先落在这里并补上断言，UI 侧只做取值与呈现。
  温度档位的阈值判定属于 `StatsCore`，档位对应的颜色留在 `MyOwnTool` 侧，由 `DESIGN.md` 管辖。
- 登录项仅支持 `.app`；不要随意修改 bundle ID 和签名逻辑，以免破坏辅助功能授权与登录项。
- 保持 macOS 15 最低版本和零第三方依赖，除非任务明确要求变更。
- 不修改用户配置、凭证、签名证书或与任务无关的工作区改动。

## 修改要求

- 修改前阅读目标模块源码与 `README.md`；涉及系统状态视觉时同时阅读 `DESIGN.md`。
- 调整系统状态的颜色、尺寸或视觉语义时，先更新 `DESIGN.md`，再同步代码。
- 图标以生成脚本为源；修改构图后重新生成 `Resources/AppIcon.icns`。
- 新增采样时明确单位、失败语义、执行线程、刷新频率和睡眠恢复行为。
- 新增 UI 时沿用程序化 AppKit 和动态系统色，检查浅色、深色、菜单栏空间与失焦行为。
- 新增用户可见功能、配置、权限或运行步骤时同步更新 `README.md`。
- 无法执行依赖硬件、授权或网络的验证时，在交付说明中明确未验证项。

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

## 版本号与标签

版本号与 git 标签使用同一个字符串，一律不带 `v` 前缀，形如 `0.2`。

`CFBundleShortVersionString` 只接受 1 到 3 段纯数字，不允许字母，
标签跟随它可以让脚本与 CI 直接取用标签名，不需要剥前缀。
`v` 前缀只有 Go modules 强制要求，本项目不适用；SwiftPM 两种写法都能解析。

标签一律用附注标签，消息格式为 `MyOwnTools <版本号>`：

```sh
git tag -a 0.2 -m "MyOwnTools 0.2"
```

改版本号时同步更新以下位置，确保全项目只存在一个版本字符串：

- `Sources/MyOwnTool/AppVersion.swift` 的 `short`，Swift 侧唯一来源；
  设置页页脚的兜底版本由它派生，不要再写字面量
- `README.md` 开头的当前版本
- `scripts/make-app.sh` 中 Info.plist 的 `CFBundleShortVersionString`
