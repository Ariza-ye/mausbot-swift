# MausBot for macOS

English | [简体中文](README_zh.md)

MausBot is a native macOS client for OpenMausBot, built with SwiftUI. It connects
to the OpenMausBot desktop app running on another computer and pairs this Mac as a
device. Use it for conversations, approvals, rooms, model selection, and
notifications; the remote OpenMausBot manages Bots and their tools.

The [companion protocol](https://github.com/johnson020202/OpenMausBot/blob/android/native-companion-client/apps/android/docs/companion-protocol.md)
documents the API used as a reference. The interface is built natively for macOS
and does not reuse the desktop harness.

## Opening the app for the first time

Download the DMG from the [latest release](https://github.com/Ariza-ye/mausbot-swift/releases/latest),
open it, and drag `MausBot.app` to Applications.

The current release is not notarized by Apple. If macOS blocks it on first launch,
open System Settings → Privacy & Security, find the MausBot message, and click
“Open Anyway”.

If macOS says the app is damaged, make sure you downloaded it from this project's
official Release and moved it to Applications, then run this in Terminal:

```bash
sudo xattr -r -d com.apple.quarantine /Applications/MausBot.app
```

## Features

- **Multiple computers:** Pair using a link or an address and pairing code, switch computers, set local names, inspect connection addresses, reconnect, and forget devices.
- **Conversations and rooms:** Browse Bots and rooms, create rooms and conversations, switch tasks (conversations), load older messages, mark messages as read, and search globally. Selecting a bot opens its most recently active conversation.
- **Sidebar organization:** Create sections, choose their Bots, and move Bots between sections.
- **Chat:** Stream replies, choose a work location for each bot conversation, render Markdown with code highlighting, math, and Mermaid, upload and preview images, save attachments, export conversations, stop replies, and delete queued messages. Rooms currently support text messages only.
- **Activity messages:** Consecutive tool activities are grouped into expandable sections with summaries, execution status, and failure counts.
- **Approvals and questions:** Allow, deny, or always allow requests, and answer using options or free text.
- **Bot management:** Create and rename Bots, edit standing instructions, pin or hide them, configure notifications and models, and set custom Emoji icons locally.
- **Native experience:** macOS notifications while the app is running, system/light/dark themes, a choice of installed fonts, and keyboard shortcuts for sending messages.
- **Updates:** Check GitHub Releases manually or on a configurable schedule.
- **Connection recovery:** Reconnect SSE streams with backoff, save event cursors per computer, merge streaming frames, and reload data when the server cannot resume a stream.
- **Encrypted transport:** Official E2E v1, direct Wi-Fi / Tailscale WebSocket connections, and Relay, with upgrades for existing pairings.

Voice, browser or computer screen streaming, routine editing, and cloud accounts
are not currently supported; their controls are not exposed.

## Build and run

Requires macOS 15+ and Xcode 26+.

```bash
xcodebuild -project MausBot.xcodeproj -scheme MausBot -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/MausBot.app
```

Alternatively, open `MausBot.xcodeproj` in Xcode and run the app. The app is
sandboxed and requests network access, a loopback-only listener for encrypted
connections, and read/write access to files selected by the user (for saving
attachments and exporting conversations).

## Package a DMG

```bash
mkdir -p build-release
./scripts/package-dmg.sh
# → dist/MausBot-<version>.dmg (universal: arm64 + x86_64)
```

Create `build-release` before the first package build; the script writes its
build log there. It builds a universal Release, verifies the signature, reports
the architectures, mounts the image read-write to set its volume icon, then
compresses it to UDZO and verifies it. Open the DMG and drag `MausBot.app` to
`Applications` to install.

The project uses ad-hoc signing (`Sign to Run Locally`) by default. To distribute
to other users, sign with a Developer ID and notarize the app. The script handles
signing but does not notarize automatically. For example:

```bash
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/package-dmg.sh
APP_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build-release/Build/Products/Release/MausBot.app/Contents/Info.plist)
xcrun notarytool submit "dist/MausBot-$APP_VERSION.dmg" --keychain-profile "YOUR_PROFILE" --wait
xcrun stapler staple "dist/MausBot-$APP_VERSION.dmg"
```

Replace `YOUR_PROFILE` with your configured notarytool keychain profile.
The optional `SIGN_IDENTITY` step re-signs the app without preserving its
entitlements, so the resulting app no longer has the Xcode build's sandbox or
its file and network entitlements. Configure signing accordingly before
distributing a sandboxed build.

Push a tag matching the app version (for example, `v0.1.1`) to build a universal
DMG and create a GitHub Release. You can also run the release workflow manually
with an existing tag. Automated releases are ad-hoc signed and not notarized.

## Pairing

Pairing codes can only be generated by OpenMausBot on the **remote computer**
(desktop app → Settings → Remote Access). This client does not generate codes.

Choose either method:

1. **Pairing link:** Paste `openmausbot://pair?address=…&port=…&token=…`, or open
   the link directly in the app (the `openmausbot` scheme is registered in
   `CFBundleURLTypes`). A link can advertise multiple prioritized `endpoints`.
   Encrypted pairing tries direct routes first and can use Relay; legacy pairing
   follows the advertised priority, with no plaintext fallback when the preferred
   route is hosted or tailnet.
2. **Address + 6-digit pairing code:** Enter an address such as
   `192.168.1.8:8787`. If no port is provided, the client tries `8787` and then
   `8810`. A plain LAN address can send the pairing code and returned device token
   over HTTP before an E2E key is pinned. A complete link containing `e2e`
   authenticates and encrypts pairing from the start.

After pairing, the device token is stored in the login Keychain (service
`com.openmausbot.mac.device-token`). The computer list is stored in the app
sandbox at `Application Support/MausBot/computers.json`. SSE cursors are saved
per computer and sent as `Last-Event-ID` when reconnecting.

### Encrypted connections and upgrading existing pairings

The latest official desktop app records a device's `e2eAt` after an actual
encrypted session rather than relying on the client version. Version 0.1.0 only
supports the legacy HTTP protocol and will be marked as an old client after the
legacy public channel is retired.

Version 0.1.1 and later support official E2E v1: CryptoKit P-256 / AES-GCM /
SHA-256 Noise handshakes, yamux multiplexing, direct Wi-Fi/Tailscale WebSocket
connections, Relay admission, and encrypted connections. The `e2e` identity
public key in the pairing link is pinned. Once pinned, only encrypted
connections are used; the client never falls back to HTTP or the legacy hosted
channel. Messages, SSE, uploads, and downloads share the same transport.

Existing pairings are upgraded by fetching the public key from the trusted
`/api/companion/endpoints` endpoint. If the device token has been revoked or the
computer rejects the legacy protocol, generate a new complete pairing link on the
computer and pair again in this app. The upgrade does not modify the User-Agent,
forge device markers, or disable server checks.

The encrypted connection's loopback proxy binds only to `127.0.0.1` on a random
port and requires a secret 32-byte request header generated at each launch.
Unauthorized local connections are rejected before an encrypted stream is
created.

## Usage

### Conversations and Bot settings

Select a Bot or room on the left. Use the conversation menu at the top of a Bot
chat to switch tasks or start a new conversation, and the model menu to change
the current conversation's model. The chat menu offers Mark as Read and Export
Conversation.

Use the sidebar's `+` menu to create a Bot, add a section, or create a group room.
A group requires at least one Bot. Use a regular Bot's context menu to move it
to a section.

Press `Enter` to send, `Shift + Enter` for a new line, or `⌘ + Enter` to send.
Use the paperclip to upload one image of up to 20 MiB in a Bot conversation;
rooms currently support text messages only. The work location menu selects a
cloud desktop, private desktop, paired computer, or browser for the current Bot
conversation, subject to the remote configuration and model capabilities. Auto
or Follow the bot's setting restores its default. The remote OpenMausBot saves
the selection; "paired computer" means the computer running OpenMausBot. Wait
for the conversation to finish before changing its location. Consecutive tool
activities are collapsed into an Activity group, which can be expanded to inspect
each result.

Open Bot Settings from the sidebar context menu or the chat menu to change the
name, standing instructions, pinning, visibility, notifications, default model,
and thinking effort. Standing instructions are sent with each message and are
limited to 24,000 UTF-8 bytes. Thinking effort options depend on the model
capabilities reported by the remote computer; choose Default to use the engine's
default. Select Change Icon next to the avatar to browse by category, search, or
paste a single Emoji, including skin tones and combined Emoji. You can also
restore the default avatar. Icons are stored locally per computer and Bot and do
not change the remote Bot's configuration.

### Computer management and preferences

Use the upper-left menu to switch paired computers, or press `⌘ + Shift + N` to
pair a new one. App settings let you switch between English and Simplified
Chinese, change the theme and font, control reply notifications, connect or
disconnect, and manage paired computers. The language selection is stored
locally and takes effect immediately. Notifications require the app to be running.

In Settings → Updates, check for a new release manually or enable automatic
checks every day, week, or 30 days. Automatic checks are enabled daily by default;
the download link opens GitHub Releases and updates are installed manually.

Use Edit on a computer to set a local name and inspect connection addresses, the
last-used address, and Relay information. Leave the local name blank to use the
remote name. Forget removes the local record and Keychain credentials; revoking
the remote device must still be done in OpenMausBot on that computer.

## Self-checks

`SelfCheck` runs from the built app on the command line without opening a window:

```bash
APP=build/Build/Products/Debug/MausBot.app/Contents/MacOS/MausBot
"$APP" --selfcheck protocol          # parsing, routing, cards, activity groups, Emoji, frame merging, Keychain
"$APP" --selfcheck markdown-ui       # Markdown preview, copy selection, scrolling, and sanitization
"$APP" --selfcheck e2e               # official E2E test vectors
```

End-to-end checks use a mock computer (Python 3 standard library, no dependencies):

```bash
python3 tools/mock-companion.py --port 8799 &
"$APP" --selfcheck all --url http://127.0.0.1:8799 --credential 123456
"$APP" --selfcheck app --url http://127.0.0.1:8799 --credential 123456 --mock-locations
```

`all` covers health checks, pairing, the Bot list, sending and reading back
messages, and the event stream. `app` exercises the full `AppStore` flow:
pair → connect → list → send → streaming reply → approval card response → forget
computer. The Keychain and computer list are cleaned up afterward.

The encrypted protocol is not verified using the legacy mock. The official
reference is pinned to
[`milind-soni/OpenMausBot@6f226f1`](https://github.com/milind-soni/OpenMausBot/tree/6f226f15def56c697626f2ed6dffac416510c79a/companion/src/e2e).
`--selfcheck e2e` checks the official V1–V4 key derivation, both handshakes, and
transport records. Test vectors are in `MausBot/Resources/e2e-vectors.json`.

The full interoperability check requires Node 24+ and a source directory
containing the official `companion/src`:

```bash
python3 tools/check-e2e.py --reference /path/to/OpenMausBot --relay
```

The check covers the official interop server, 3 MiB bidirectional transfers and
window updates, concurrent requests, SSE, and loopback access control. Pairing
tests use the official `DeviceRegistry`, `E2ERegistry`, and proxy directly,
mocking only harness responses, and assert that the real `e2eAt` is recorded and
legacy HTTP returns 426. They also cover automatic upgrades of existing pairings
and Relay admission/ready/Noise communication. `--relay` uses a local relay
entry point available only in Debug builds. Without that flag, the check can run
against a Release or DMG executable (specified with `--app`).

UI screenshots can be rendered offscreen without screen-recording permission
(one per process, to avoid SwiftUI assertions from state updates after rendering):

```bash
"$APP" --render onboarding            # first-time pairing
"$APP" --render gallery               # bubbles, Markdown, approval cards, tool rows
"$APP" --render pairing               # pairing sheet
"$APP" --render settings              # app settings and computer list
"$APP" --render computer-edit         # local name and connection details (sample data)
"$APP" --render emoji-picker          # Emoji icon picker
"$APP" --render chat --url http://127.0.0.1:8799 --credential 123456
"$APP" --render bot-settings --url http://127.0.0.1:8799 --credential 123456
```

Images are written to `tmp/mausbot-render/` inside the app container. `chat` and
`bot-settings` require a paired computer; the commands above use the mock service.

## Structure

```
MausBot/
  Core/
    ApiClient.swift        HTTP / attachment uploads / pairing
    SSE.swift              Event stream reader (splits blank lines itself; AsyncLineSequence drops them)
    E2ECrypto.swift        Official E2E v1 key derivation, identity verification, Noise, and transport records
    E2EConnection.swift    WebSocket / Relay / yamux / protected loopback proxy
    AppStore.swift         Single state machine: connection, frame merging, optimistic sends, actions
    ComputerStore.swift    Computer list, local names, and route consent persistence
    PairingInvite.swift    Link / QR code / manual pairing parsing
    CompanionEndpoint.swift Address validation and fallback policy
    Keychain.swift         Device tokens
    Models.swift           Tolerant wire-model parsing
    UpdateChecker.swift    GitHub release checks and scheduling
  UI/                      SwiftUI interface, activity groups, Emoji picker, and Markdown rendering
  Resources/               AppIcon (reused from upstream), AccentColor, and E2E test vectors
  SelfCheck.swift          Headless self-checks
  E2ESelfCheck.swift       Official vectors, transport interoperability, and pairing upgrade checks
tools/mock-companion.py    Mock computer for end-to-end tests
tools/check-e2e.py         Official E2E interoperability check entry point
tools/e2e-companion-test.mjs Official companion pairing and Relay test fixture
scripts/package-dmg.sh     Universal Release build and DMG packaging
```

## Security boundaries

- `NSAllowsArbitraryLoads` allows connections to LAN addresses such as
  `http://192.168.x.x`. Once an E2E public key is pinned, the device token is
  sent only through an authenticated encrypted channel.
- Without an E2E key, plaintext routes (LAN/Bonjour) are used only for addresses
  selected during pairing. Once connected through hosted/tailnet, subsequent
  automatic reconnections will not downgrade to plaintext LAN/Bonjour.
- Forgetting a computer deletes the Keychain token, but does not and cannot
  revoke the device remotely. Revoke it in the computer's Remote Access settings.

## Icons and licensing

The app icon (`MausBot/Resources/Assets.xcassets/AppIcon.appiconset`) is reused
directly from `build/icon.iconset` in the official OpenMausBot repository. It is
copyright the OpenMausBot authors and provided upstream under the Apache License
2.0.

E2E test vectors also come from the pinned official commit above. See
`OpenMausBot-LICENSE.txt` and `OpenMausBot-NOTICE.txt` in the app resources for
licensing and attribution.

Model provider icons are from LobeHub and use the MIT License; see
`MausBot/Resources/ProviderIcons-LICENSE.txt`.
