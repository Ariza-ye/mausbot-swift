# MausBot for macOS

OpenMausBot 的 macOS 原生客户端（SwiftUI）。它连接另一台电脑上运行的
OpenMausBot 桌面端，把这台 Mac 当作配对设备：对话、审批卡片、房间、
模型切换、任务和通知都在这里完成；智脑、工具、文件和凭证始终留在远程电脑上。

需求见 [SPEC.md](SPEC.md)。协议以
[companion-protocol.md](https://github.com/johnson020202/OpenMausBot/blob/android/native-companion-client/apps/android/docs/companion-protocol.md)
为准，界面按原生 macOS 重做，不复用桌面端 harness。

## 构建与运行

需要 macOS 15+ 与 Xcode 16+。

```bash
xcodebuild -project MausBot.xcodeproj -scheme MausBot -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/MausBot.app
```

或者直接用 Xcode 打开 `MausBot.xcodeproj` 运行。App 是沙盒化的，只申请
网络连接、仅绑定回环地址的加密通道监听，以及用户选择文件的读写（保存附件与导出对话）。

## 打包 DMG

```bash
./scripts/package-dmg.sh
# → dist/MausBot-<版本>.dmg（universal：arm64 + x86_64）
```

脚本会构建 Release、验证签名与架构、做一次可写挂载给卷设置图标，再压缩成
UDZO 镜像。工程默认是 ad-hoc 签名（`Sign to Run Locally`），本机双击可用；
要分发给别人需要 Developer ID 与公证，例如：

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh
xcrun notarytool submit dist/MausBot-0.1.1.dmg --keychain-profile <profile> --wait
```

## 配对

配对码只能由**远程电脑**上的 OpenMausBot 生成（桌面端 → 设置 → 远程访问）。
这个客户端不生成配对码。

两种入口，任一都可以：

1. **配对链接**：粘贴 `openmausbot://pair?address=…&port=…&token=…`，也支持
   从链接直接打开 App（`CFBundleURLTypes` 已注册 `openmausbot` scheme）。
   链接里的 `endpoints`（base64url 的 JSON）会按 `priority` 依次探测；
   带有 `https` 的 hosted 路由优先，且绝不会回退到明文地址。
2. **地址 + 6 位配对码**：手动输入 `192.168.1.8:8787`。不写端口时会依次
   尝试 `8787` 和 `8810`。

配对成功后设备令牌写入登录钥匙串（service `com.openmausbot.mac.device-token`），
电脑列表保存在 App 沙盒的 `Application Support/MausBot/computers.json`，
SSE 游标按电脑分别保存，断线后带 `Last-Event-ID` 续传。

### 0.1.1：修复“older MausBot app”提示

最新版官方桌面端通过真实加密会话写入设备的 `e2eAt`，而不是根据版本号判断。
0.1.0 只有旧 HTTP 协议，会在旧公网通道退役后被标为旧客户端。

0.1.1 实现官方 E2E v1：CryptoKit 的 P-256 / AES-GCM / SHA-256 Noise 握手、
yamux 多路复用、Wi-Fi/Tailscale WebSocket 直连、Relay admission 与加密连接。
配对链接里的 `e2e` 身份公钥会固定保存；一旦固定，只使用加密连接，绝不退回
HTTP 或旧 hosted 通道。消息、SSE、上传和下载共用相同的传输。

旧配对记录会通过已信任的 `/api/companion/endpoints` 获取公钥并升级；如果设备
令牌已撤销或电脑拒绝旧协议，请在电脑上生成新的完整配对链接，然后在此 App
重新配对。这个升级不会靠修改 User-Agent、伪造设备标记或关闭服务端检查实现。

加密连接的回环代理只绑定 `127.0.0.1` 随机端口，并要求每次启动生成的 32 字节
秘密请求头；未授权本地连接在创建加密流前被拒绝。

## 已实现

- 配对：链接 / 地址+码、多地址探测、hosted 优先的路由策略、多台电脑切换
- 会话：bot 列表、房间、任务（对话）切换、历史分页、未读、置顶、隐藏
- 发送：乐观气泡、`clientId` 去重、图片上传、停止本轮、队列消息删除
- 审批与提问：`allow` / `deny` / `answer`（含自由文本）、始终允许
- 实时：SSE 断线抖动退避重连、`message.patch` 流式合并、`hello.resumed`
  为假时重新拉取
- 模型：`/api/instances` 列表与切换
- 其他：全局搜索、bot 改名/通知开关、新建 bot、macOS 通知、深色模式

不在本期：语音、浏览器/电脑画面串流、例程编辑、云端账号。这些属于桌面端
或更重的传输能力，客户端相应入口被隐藏而不是伪造。

## 自检

`SelfCheck` 以命令行方式跑在构建产物内部，不打开窗口：

```bash
APP=build/Build/Products/Debug/MausBot.app/Contents/MacOS/MausBot
"$APP" --selfcheck protocol          # 解析、路由策略、卡片、帧合并、钥匙串
```

端到端检查用一个 mock 电脑（Python 3 标准库，无依赖）：

```bash
python3 tools/mock-companion.py --port 8799 &
"$APP" --selfcheck all --url http://127.0.0.1:8799 --credential 123456
"$APP" --selfcheck app --url http://127.0.0.1:8799 --credential 123456
```

`all` 覆盖健康检查、配对、bot 列表、发送回读和事件流；`app` 走完整的
`AppStore`：配对 → 连接 → 列表 → 发送 → 流式回复 → 审批卡回复 → 忘记电脑，
结束时自动清理钥匙串和电脑列表。

加密协议不是用旧 mock 验证：官方参考代码固定于
`milind-soni/OpenMausBot@6f226f15def56c697626f2ed6dffac416510c79a`。
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
"$APP" --render chat --url http://127.0.0.1:8799 --credential 123456
```

图片写到 App 容器内的 `tmp/mausbot-render/`。

## 结构

```
MausBot/
  Core/
    ApiClient.swift        HTTP / 附件上传 / 配对
    SSE.swift              事件流读取（自己拆空行，AsyncLineSequence 会丢空行）
    E2ECrypto.swift        官方 E2E v1 密钥派生、身份校验、Noise 与传输记录
    E2EConnection.swift    WebSocket / Relay / yamux / 受保护回环代理
    AppStore.swift         单一状态机：连接、帧合并、乐观发送、动作
    ComputerStore.swift    电脑列表持久化与路由同意
    PairingInvite.swift    链接/二维码/手动配对解析
    CompanionEndpoint.swift 地址校验与回退策略
    Keychain.swift         设备令牌
    Models.swift           宽容解析的 wire 模型
  UI/                      SwiftUI 界面
  Resources/               AppIcon（复用官方图标）与 AccentColor
  SelfCheck.swift          无窗口自检
  E2ESelfCheck.swift       官方向量、传输互通及旧配对升级检查
tools/mock-companion.py    端到端测试用的假电脑
```

## 安全边界

- `NSAllowsArbitraryLoads` 只是为了让局域网 `http://192.168.x.x` 能连；
  对带有 E2E 公钥的电脑，令牌只在经过身份验证的加密通道里发送。
- 明文路由（LAN/Bonjour）只在配对时显式同意过的地址上使用；一旦连上
  hosted/tailnet，后续自动重连不会再降级回明文。
- 忘记电脑会删除钥匙串令牌，但不会也无法在远程电脑上撤销设备；需要在
  电脑的远程访问设置里撤销。

## 图标与许可

App 图标（`MausBot/Resources/Assets.xcassets/AppIcon.appiconset`）直接复用
OpenMausBot 官方仓库的 `build/icon.iconset`，版权归 OpenMausBot 作者，
随上游以 Apache License 2.0 提供。

E2E 测试向量同样来自上述固定的官方提交；许可和来源见 App 资源内的
`OpenMausBot-LICENSE.txt` 与 `OpenMausBot-NOTICE.txt`。
