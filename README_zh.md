# MausBot for macOS

[English](README.md) | 简体中文

OpenMausBot 的 macOS 原生客户端（SwiftUI）。它连接另一台电脑上运行的
OpenMausBot 桌面端，把这台 Mac 当作配对设备：在这里进行对话、审批、房间聊天和
模型切换，并接收通知；Bot 及其工具由远程 OpenMausBot 管理。

API 以 [companion-protocol.md](https://github.com/johnson020202/OpenMausBot/blob/android/native-companion-client/apps/android/docs/companion-protocol.md)
为参考，界面按原生 macOS 重做，不复用桌面端 harness。

## 首次打开

从[最新发布页](https://github.com/Ariza-ye/mausbot-swift/releases/latest)下载 DMG，
打开后将 `MausBot.app` 拖入「应用程序」文件夹。

当前发布版本未经 Apple 公证。首次打开被拦截时，请前往「系统设置」→「隐私与安全性」，
找到 MausBot 的提示并点击「仍要打开」。

如果提示应用“已损坏”，请确认应用来自本项目的官方 Release，并已拖入「应用程序」文件夹，
然后在终端执行：

```bash
sudo xattr -r -d com.apple.quarantine /Applications/MausBot.app
```

## 功能

- **多台电脑**：通过配对链接或地址与配对码连接，切换电脑、设置本机备注、查看连接地址、重新连接与忘记设备。
- **对话与房间**：Bot 列表、新建房间和对话、任务（对话）切换、历史分页、未读标记和全局搜索。选择 Bot 时默认打开最近有消息的对话。
- **侧栏整理**：创建区段、选择区段内的 Bot，以及在区段之间移动 Bot。
- **聊天**：流式回复、对话运行位置选择、Markdown（代码高亮、公式与 Mermaid）、图片上传与预览、附件保存、对话导出、停止本轮和删除队列消息。房间目前只发送文字。
- **活动消息**：连续的工具活动合并为可展开的分组，显示摘要、执行状态和失败数量。
- **审批与提问**：允许、拒绝、始终允许，以及选项和自由文本回答。
- **Bot 管理**：新建、改名、常驻指示、置顶、隐藏、通知开关、模型切换与本机自定义 Emoji 图标。
- **原生体验**：运行期间的 macOS 通知、跟随系统 / 浅色 / 深色主题、本机字体选择和键盘发送快捷键。
- **软件更新**：手动或按设定频率检查 GitHub Release。
- **连接恢复**：SSE 断线退避重连、按电脑保存事件游标、流式帧合并；服务端无法续传时重新拉取数据。
- **加密传输**：官方 E2E v1、Wi-Fi / Tailscale WebSocket 直连与 Relay，支持旧配对记录升级。

暂不支持语音、浏览器/电脑画面串流、例程编辑和云端账号，相关入口未开放。

## 构建与运行

需要 macOS 15+ 与 Xcode 26+。

```bash
xcodebuild -project MausBot.xcodeproj -scheme MausBot -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/MausBot.app
```

或者直接用 Xcode 打开 `MausBot.xcodeproj` 运行。App 是沙盒化的，只申请
网络连接、仅绑定回环地址的加密通道监听，以及用户选择文件的读写（保存附件与导出对话）。

## 打包 DMG

```bash
mkdir -p build-release
./scripts/package-dmg.sh
# → dist/MausBot-<版本>.dmg（universal：arm64 + x86_64）
```

首次打包先创建 `build-release`，脚本会把构建日志写入该目录。
脚本构建 universal Release，验证签名并输出架构，做一次可写挂载给卷设置图标，
再压缩成 UDZO 镜像并校验。打开 DMG 后，将 `MausBot.app` 拖到 `Applications` 安装。

工程默认使用 ad-hoc 签名（`Sign to Run Locally`）。面向其他用户分发时，
应使用 Developer ID 签名并完成公证；脚本只负责签名，不会自动公证。例如：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build-release/Build/Products/Release/MausBot.app/Contents/Info.plist)
xcrun notarytool submit "dist/MausBot-$APP_VERSION.dmg" --keychain-profile "YOUR_PROFILE" --wait
xcrun stapler staple "dist/MausBot-$APP_VERSION.dmg"
```

将 `YOUR_PROFILE` 替换为已配置的 notarytool 钥匙串配置名称。
使用 `SIGN_IDENTITY` 时，脚本重签名不会保留原有权限，生成的 App 会失去 Xcode
构建时的沙盒及文件、网络权限。分发沙盒版本前需相应配置签名。

推送与应用版本一致的标签（例如 `v0.1.1`）后，GitHub Actions 会构建通用架构
DMG 并创建 GitHub Release。也可以在 Actions 中手动运行“发布 macOS DMG”，
输入已有标签。自动发布的包使用 ad-hoc 签名，未经过 Apple 公证。

## 配对

配对码只能由**远程电脑**上的 OpenMausBot 生成（桌面端 → 设置 → 远程访问）。
这个客户端不生成配对码。

两种入口，任一都可以：

1. **配对链接**：粘贴 `openmausbot://pair?address=…&port=…&token=…`，也支持
   从链接直接打开 App（`CFBundleURLTypes` 已注册 `openmausbot` scheme）。
   链接可包含多个带优先级的 `endpoints`。加密配对优先尝试直连，也可以通过 Relay；
   旧协议按路由优先级尝试，首选 hosted 或 tailnet 时不会回退到明文局域网地址。
2. **地址 + 6 位配对码**：手动输入 `192.168.1.8:8787`。不写端口时会依次
   尝试 `8787` 和 `8810`。使用普通局域网地址时，在固定 E2E 公钥之前，配对码和
   返回的设备令牌可能通过 HTTP 明文传输。包含 `e2e` 的完整配对链接从配对开始就会
   验证身份并加密。

配对成功后设备令牌写入登录钥匙串（service `com.openmausbot.mac.device-token`），
电脑列表保存在 App 沙盒的 `Application Support/MausBot/computers.json`，
SSE 游标按电脑分别保存，断线后带 `Last-Event-ID` 续传。

### 加密连接与旧配对升级

最新版官方桌面端通过真实加密会话写入设备的 `e2eAt`，而不是根据版本号判断。
0.1.0 只有旧 HTTP 协议，会在旧公网通道退役后被标为旧客户端。

从 0.1.1 起支持官方 E2E v1：CryptoKit 的 P-256 / AES-GCM / SHA-256 Noise 握手、
yamux 多路复用、Wi-Fi/Tailscale WebSocket 直连、Relay admission 与加密连接。
配对链接里的 `e2e` 身份公钥会固定保存；一旦固定，只使用加密连接，绝不退回
HTTP 或旧 hosted 通道。消息、SSE、上传和下载共用相同的传输。

旧配对记录会通过已信任的 `/api/companion/endpoints` 获取公钥并升级；如果设备
令牌已撤销或电脑拒绝旧协议，请在电脑上生成新的完整配对链接，然后在此 App
重新配对。这个升级不会靠修改 User-Agent、伪造设备标记或关闭服务端检查实现。

加密连接的回环代理只绑定 `127.0.0.1` 随机端口，并要求每次启动生成的 32 字节
秘密请求头；未授权本地连接在创建加密流前被拒绝。

## 使用

### 对话与 Bot 设置

在左侧选择 Bot 或房间；Bot 顶部的对话菜单可切换任务或新建对话，模型菜单可
切换当前对话的模型。聊天菜单提供标记已读和导出对话。

通过侧栏的 `+` 菜单可以新建 Bot、添加区段或新建群组房间；新建群组至少需要选择
一个 Bot。普通 Bot 的右键菜单提供“移动到区段”。

输入框中按 `Enter` 发送、`Shift + Enter` 换行，也支持 `⌘ + Enter` 发送。
Bot 对话可通过回形针上传一张不超过 20 MiB 的图片；房间当前只支持文字发送。
Bot 输入框中的运行位置菜单可以为当前对话选择云端桌面、私有桌面、配对电脑或浏览器；
可用选项取决于远程配置和模型能力。选择“自动”或“跟随 Bot 设置”会恢复 Bot 的默认
位置。位置由远程 OpenMausBot 保存，其中“配对电脑”指运行 OpenMausBot 的电脑。
对话正在运行时需等它结束再切换。
连续的工具活动会折叠到“活动”分组，展开后查看各项执行结果。

从侧栏右键菜单或聊天菜单打开“Bot 设置”，可以修改名称、长期指示、置顶、隐藏、通知、
默认模型与思考强度。长期指示随每条消息发送，最多 24,000 个 UTF-8 字节。
思考强度选项取决于远程电脑报告的模型能力；选择“默认”使用引擎默认设置。
点击头像旁的“更换图标…”可按分类浏览、搜索或粘贴单个 Emoji，支持肤色和组合表情，
也可以恢复默认头像。图标按电脑和 Bot 分别保存在本机，不会修改远程 Bot 的配置。

### 电脑管理与偏好设置

左上角菜单可切换已配对的电脑；按 `⌘ + Shift + N` 可配对新电脑。
在 App 设置中可以切换简体中文和 English、切换主题和字体、控制回复通知、连接或断开
电脑，并管理已配对列表。语言设置会保存在本机，切换后立即生效。通知需要 App 保持运行。

在「设置」→「更新」中可手动检查新版本，也可设置每天、每周或每 30 天自动检查。
默认每天自动检查；下载链接会打开 GitHub Release，更新需要手动安装。

电脑的“编辑”入口可设置本机备注，查看连接地址、上次使用的地址和 Relay 信息。
备注留空时使用远程电脑名称。“忘记”会删除本机记录与钥匙串凭证；远程设备撤销
仍需在那台电脑上的 OpenMausBot 中操作。

## 自检

`SelfCheck` 以命令行方式跑在构建产物内部，不打开窗口：

```bash
APP=build/Build/Products/Debug/MausBot.app/Contents/MacOS/MausBot
"$APP" --selfcheck protocol          # 解析、路由、卡片、活动分组、Emoji、帧合并、钥匙串
"$APP" --selfcheck markdown-ui       # Markdown 预览、复制选区、滚动与内容清理
"$APP" --selfcheck e2e               # 官方 E2E 测试向量
```

端到端检查用一个 mock 电脑（Python 3 标准库，无依赖）：

```bash
python3 tools/mock-companion.py --port 8799 &
"$APP" --selfcheck all --url http://127.0.0.1:8799 --credential 123456
"$APP" --selfcheck app --url http://127.0.0.1:8799 --credential 123456 --mock-locations
```

`all` 覆盖健康检查、配对、bot 列表、发送回读和事件流；`app` 走完整的
`AppStore`：配对 → 连接 → 列表 → 发送 → 流式回复 → 审批卡回复 → 忘记电脑，
结束时自动清理钥匙串和电脑列表。

加密协议不是用旧 mock 验证：官方参考代码固定于
[`milind-soni/OpenMausBot@6f226f1`](https://github.com/milind-soni/OpenMausBot/tree/6f226f15def56c697626f2ed6dffac416510c79a/companion/src/e2e)。
`--selfcheck e2e` 校验官方 V1–V4 的密钥派生、两种握手和传输记录；测试向量
位于 `MausBot/Resources/e2e-vectors.json`。

完整互通检查需要 Node 24+ 与包含官方 `companion/src` 的源码目录：

```bash
python3 tools/check-e2e.py --reference /path/to/OpenMausBot --relay
```

检查包含官方 interop server、3 MiB 双向传输与窗口更新、并发请求、SSE、回环
访问控制；配对测试直接使用官方的 `DeviceRegistry`、`E2ERegistry` 和 proxy，
只模拟 harness 的回复，并断言真实 `e2eAt` 已写入、旧 HTTP 已返回 426。
同时覆盖旧配对记录自动升级和 Relay admission/ready/Noise 通信。
`--relay` 使用 Debug 构建专用的本地 relay 入口，发布版没有该入口；不带该
参数可对 Release 或 DMG 中的可执行文件运行检查（用 `--app` 指定）。

界面截图可以在没有录屏权限的机器上离屏渲染（一次进程一张，避免 SwiftUI
在渲染后收到状态更新而断言）：

```bash
"$APP" --render onboarding            # 首次配对
"$APP" --render gallery               # 气泡、Markdown、审批卡、工具行
"$APP" --render pairing               # 配对弹窗
"$APP" --render settings              # App 设置与电脑列表
"$APP" --render computer-edit         # 电脑备注与连接信息（示例数据）
"$APP" --render emoji-picker          # Emoji 图标选择器
"$APP" --render chat --url http://127.0.0.1:8799 --credential 123456
"$APP" --render bot-settings --url http://127.0.0.1:8799 --credential 123456
```

图片写到 App 容器内的 `tmp/mausbot-render/`。
`chat` 和 `bot-settings` 需要已配对的电脑，以上命令使用前面的 mock 服务。

## 结构

```
MausBot/
  Core/
    ApiClient.swift        HTTP / 附件上传 / 配对
    SSE.swift              事件流读取（自己拆空行，AsyncLineSequence 会丢空行）
    E2ECrypto.swift        官方 E2E v1 密钥派生、身份校验、Noise 与传输记录
    E2EConnection.swift    WebSocket / Relay / yamux / 受保护回环代理
    AppStore.swift         单一状态机：连接、帧合并、乐观发送、动作
    ComputerStore.swift    电脑列表、本机备注持久化与路由同意
    PairingInvite.swift    链接/二维码/手动配对解析
    CompanionEndpoint.swift 地址校验与回退策略
    Keychain.swift         设备令牌
    Models.swift           宽容解析的 wire 模型
    UpdateChecker.swift    GitHub 发布版本检查与调度
  UI/                      SwiftUI 界面、活动分组、Emoji 选择器与 Markdown 渲染
  Resources/               AppIcon（复用官方图标）、AccentColor 与 E2E 测试向量
  SelfCheck.swift          无窗口自检
  E2ESelfCheck.swift       官方向量、传输互通及旧配对升级检查
tools/mock-companion.py    端到端测试用的假电脑
tools/check-e2e.py         官方 E2E 互通检查入口
tools/e2e-companion-test.mjs 官方 companion 配对与 Relay 测试夹具
scripts/package-dmg.sh     universal Release 构建与 DMG 打包
```

## 安全边界

- `NSAllowsArbitraryLoads` 只是为了让局域网 `http://192.168.x.x` 能连；
  固定 E2E 公钥后，设备令牌只在经过身份验证的加密通道里发送。
- 没有 E2E 公钥时，明文路由（LAN/Bonjour）只使用配对时选择的地址；一旦连上
  hosted/tailnet，后续自动重连不会再降级到明文 LAN/Bonjour。
- 忘记电脑会删除钥匙串令牌，但不会也无法在远程电脑上撤销设备；需要在
  电脑的远程访问设置里撤销。

## 图标与许可

App 图标（`MausBot/Resources/Assets.xcassets/AppIcon.appiconset`）直接复用
OpenMausBot 官方仓库的 `build/icon.iconset`，版权归 OpenMausBot 作者，
随上游以 Apache License 2.0 提供。

E2E 测试向量同样来自上述固定的官方提交；许可和来源见 App 资源内的
`OpenMausBot-LICENSE.txt` 与 `OpenMausBot-NOTICE.txt`。

模型提供商图标来自 LobeHub，采用 MIT 许可，详见
`MausBot/Resources/ProviderIcons-LICENSE.txt`。
