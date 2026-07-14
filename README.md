# MyOwnTool

个人 macOS 菜单栏工具（Swift + AppKit，无第三方依赖）。

当前已实现：**Shift 拖拽分屏**。规划中：AI 订阅使用率菜单栏显示、系统状态显示。

## 功能：Shift 拖拽分屏

按住 **Shift** 拖动任意窗口时，所有屏幕上会浮现浅色半透明的分区标记；把鼠标移入某个分区（该分区会高亮），松开鼠标，窗口即自动缩放并吸附到该区域。拖动途中松开 Shift 即取消（再按下可恢复）。

修饰键选 Shift 而非 Option：Option-点按另一 App 的窗口会触发系统「隐藏当前 App」的默认行为，规避它需要能改写事件流的 CGEventTap，而主动式 tap 会给全局鼠标事件增加一跳延迟；Shift 在 macOS 中没有窗口级的系统互动，用只读的事件监视器即可实现，不影响系统事件投递。窗口内容区的 Shift 操作（如扩展选区）也不受影响——只有窗口真的被拖动时才会显示分区标记。

每个显示器可使用不同布局：

- **内置显示器**（MacBook 屏幕）：左右对半分。
- **外接显示器**：三分之一网格布局——上方 2/3 高度分为「1·主区（左 2/3）」和「2·右栏（右 1/3）」，下方 1/3 高度为「A·底左」「B·底中」「C·底右」三格。

```
┌──────────────────┬─────────┐
│                  │         │
│      1·主区      │  2·右栏 │
│                  │         │
├────────┬─────────┼─────────┤
│ A·底左 │  B·底中 │  C·底右 │
└────────┴─────────┴─────────┘
```

## 构建与运行

需要 Xcode Command Line Tools（`xcode-select --install`），无需完整 Xcode。

```sh
# 开发调试
swift build
.build/debug/MyOwnTool

# 打包为 .app（推荐日常使用，授权更稳定）
./scripts/make-app.sh
open build/MyOwnTool.app
```

首次启动会弹出「辅助功能」授权提示（控制其他应用窗口必须此权限）。到 **系统设置 → 隐私与安全性 → 辅助功能** 中勾选本应用即可，授权后无需重启应用。

### 签名与权限保持

打包脚本默认用钥匙串中名为 `MyOwnToolSigning` 的自签名代码签名证书签名（在「钥匙串访问 → 证书助理 → 创建证书」中创建，证书类型选「代码签名」）。签名身份稳定后，「辅助功能」授权在重新构建/更新后依然有效，无需重新勾选。

临时改用其他身份：`CODESIGN_IDENTITY=- ./scripts/make-app.sh`（`-` 为 ad-hoc 签名，每次重编译后需重新授权）。裸二进制（`.build/debug/MyOwnTool`）调试运行同样存在重编译后需重新授权的问题。

### 开机自启

菜单栏图标 → 勾选「开机时自动启动」（通过 `SMAppService` 注册为登录项，可在 系统设置 → 通用 → 登录项 中查看）。该菜单项仅在以 .app 形式运行时显示，裸二进制不支持。

移动 .app 位置（如拖入「应用程序」）后：辅助功能授权**不受影响**（TCC 绑定的是 bundle ID + 签名证书，与路径无关）；登录项记录的是注册时的路径，但应用每次启动时会自动以当前位置刷新注册，所以移动后从新位置手动打开一次即可，若菜单中自启变为未勾选则重新勾选一下。推荐流程：先移动到「应用程序」，再打开并勾选自启。

### 应用图标

图标（两颗咖啡豆）由 `scripts/generate-icon.swift` 用 CoreGraphics 程序化绘制。修改配色或构图后重新生成：

```sh
swift scripts/generate-icon.swift /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o Resources/AppIcon.icns
./scripts/make-app.sh
```

## 自定义布局

菜单栏图标 → 「编辑布局配置…」会在 `~/.config/myowntool/layouts.json` 生成默认配置并打开。改完后点「重新加载布局配置」立即生效（无需重启）。

坐标为屏幕**可用区域**（自动避开菜单栏和 Dock）内的比例值，**原点在左上角**：

```json
{
  "builtin":  [ { "name": "左半屏", "x": 0, "y": 0, "w": 0.5, "h": 1 }, ... ],
  "external": [ ... ],
  "displays": {
    "DELL U2723QE": [ { "x": 0, "y": 0, "w": 0.6667, "h": 1 }, ... ]
  }
}
```

- `builtin`：所有内置显示器的布局。
- `external`：所有外接显示器的默认布局。
- `displays`（可选）：按显示器名称（系统设置 → 显示器 中的名称）单独指定，优先级最高。

分区可以重叠、也可以不铺满屏幕——没有标记的地方松手不会触发吸附。

## 项目结构

```
Sources/MyOwnTool/
├── main.swift            # 入口，菜单栏应用（accessory 模式）
├── AppDelegate.swift     # 菜单栏图标与菜单
├── Permissions.swift     # 辅助功能授权
├── Layout.swift          # 分区配置（默认值 + JSON 加载）
├── Coords.swift          # Cocoa ↔ Accessibility 坐标转换
├── AXWindow.swift        # 通过辅助功能 API 读写任意应用窗口位置尺寸
├── OverlayManager.swift  # 拖拽时的半透明分区标记层
└── SnapController.swift  # 全局鼠标事件监听与吸附逻辑
```
