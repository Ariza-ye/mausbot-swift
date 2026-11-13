import Foundation

/// A headless smoke test that runs from the built app (`MausBot.app/Contents/MacOS/MausBot --selfcheck`).
/// It covers the protocol parsers and, when a mock computer is given, pairing,
/// transcript, send and the event stream.
enum SelfCheck {
    static func runAndExit(arguments: [String]) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        // The app's store is main-actor isolated, so the checks run on the main
        // actor and the run loop keeps that actor serviced.
        Task { @MainActor in
            let status = await run(arguments)
            exit(status)
        }
        RunLoop.main.run()
        exit(1)
    }

    @MainActor
    private static func run(_ arguments: [String]) async -> Int32 {
        let command = arguments.first { !$0.hasPrefix("--") } ?? "protocol"
        #if DEBUG
        if command == "e2e-relay", let url = value(for: "--url", in: arguments).flatMap(URL.init(string:)),
           let encoded = value(for: "--descriptor", in: arguments), let descriptor = try? E2EDescriptor(encoded: encoded),
           let token = value(for: "--token", in: arguments) {
            return await E2ESelfCheck.relay(url: url, descriptor: descriptor, token: token)
        }
        #endif
        if command == "e2e" {
            return await E2ESelfCheck.run(baseURL: value(for: "--url", in: arguments))
        }
        if command == "markdown-ui" {
            return await MarkdownPreviewSelfCheck.run()
        }
        if command == "upgrade", let url = value(for: "--url", in: arguments), let token = value(for: "--token", in: arguments) {
            return await E2ESelfCheck.upgrade(baseURL: url, token: token)
        }
        guard ["protocol", "all", "pair", "stream", "chat", "app"].contains(command) else {
            print("Unknown selfcheck: \(command)")
            return 2
        }
        var failures = 0

        func check(_ name: String, _ condition: @autoclosure () -> Bool) {
            if condition() {
                print("ok   \(name)")
            } else {
                print("FAIL \(name)")
                failures += 1
            }
        }

        if command == "protocol" || command == "all" {
            check("update detects a newer numeric release", UpdateChecker.isNewer("v0.1.10", than: "0.1.9") == true)
            check("update ignores the same release", UpdateChecker.isNewer("v0.1.1", than: "0.1.1.0") == false)
            check("update ignores older releases", UpdateChecker.isNewer("v0.1.1", than: "0.2.0") == false)
            check("update rejects invalid release tags", UpdateChecker.isNewer("v0.2.0-beta", than: "0.1.1") == nil)
            let english = AppLanguage.current == .english
            check("selected language loads localized strings", localized("重新连接") == (english ? "Reconnect" : "重新连接"))
            check("localized strings format dynamic values", localized("正在连接 %@…", "Mac") == (english ? "Connecting to Mac…" : "正在连接 Mac…"))
            check("unknown localization keys fall back to the original", localized("missing.localization.key") == "missing.localization.key")
            let iconInstance = ProviderInstance(json: ["instanceId": "custom", "driverKind": "claude", "models": ["options": [["id": "gpt-6.1-sol", "provider": "openai"]]]])!
            let reasoningInstance = ProviderInstance(json: [
                "instanceId": "reasoning",
                "capabilities": ["effortLevels": ["low", "high"], "modelVariants": true],
                "models": ["options": [["id": "model", "variants": [["id": "deep", "label": "Deep"]]]]],
            ])!
            check("model reasoning capabilities parse", reasoningInstance.effortLevels == ["low", "high"] && reasoningInstance.modelVariants && reasoningInstance.models.first?.variants.first?.label == "Deep")
            let reasoningSelection = ModelSelection(instanceId: "reasoning", model: "model", effort: "high", variant: "deep")
            check("model reasoning selection round trips", ModelSelection(json: reasoningSelection.json) == reasoningSelection)
            check("model icon uses the model provider before the driver", ProviderIcon.iconName(selection: ModelSelection(instanceId: "custom", model: "gpt-6.1-sol"), instances: [iconInstance]) == "openai")
            check("model icon recognizes names without a catalog", ProviderIcon.iconName(selection: ModelSelection(instanceId: "custom", model: "deepseek-v3"), instances: []) == "deepseek")
            check("model icon falls back to the instance driver", ProviderIcon.iconName(selection: ModelSelection(instanceId: "custom", model: "unknown"), instances: [iconInstance]) == "claude")
            check("unknown model has no provider icon", ProviderIcon.iconName(selection: ModelSelection(instanceId: "unknown", model: "unknown"), instances: []) == nil)
            check("avatar accepts emoji and variation selectors", AppStore.isValidEmoji("🤖") && AppStore.isValidEmoji("❤️"))
            check("avatar accepts skin tones and joined emoji", AppStore.isValidEmoji("👩🏽‍💻") && AppStore.isValidEmoji("👨‍👩‍👧‍👦"))
            check("avatar accepts flags and keycaps", AppStore.isValidEmoji("🇸🇬") && AppStore.isValidEmoji("1️⃣"))
            check("avatar rejects text and plain digits", !AppStore.isValidEmoji("猫") && !AppStore.isValidEmoji("1"))
            check("avatar rejects empty or multiple emoji", !AppStore.isValidEmoji("") && !AppStore.isValidEmoji("🤖🐱"))
            let endpoints = #"[{"url":"http://192.168.1.8:8787","kind":"lan","priority":1},{"url":"https://abc.tailnet.ts.net","kind":"hosted","priority":0}]"#
            let encoded = Data(endpoints.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            let token = "omb_pair_" + String(repeating: "a", count: 43)
            let link = "openmausbot://pair?address=192.168.1.8&port=8787&token=\(token)&name=Mac%20Studio&endpoints=\(encoded)"
            let invite = PairingInvite.parse(link)
            check("deep link parses", invite != nil)
            check("deep link keeps the hosted route first", invite?.routes.first?.url == "https://abc.tailnet.ts.net")
            check("deep link keeps the invited name", invite?.serverName == "Mac Studio")
            check("deep link keeps both routes", invite?.routes.count == 2)
            let legacy = PairingInvite.parse("openmausbot://pair?address=192.168.1.8&code=123456&endpoints=192.168.1.8:8787,mac.local:8810")
            check("legacy comma-separated endpoints parse", legacy?.routes.count == 2)
            check("invalid typed endpoints reject the invite", PairingInvite.parse("openmausbot://pair?address=192.168.1.8&code=123456&endpoints=invalid") == nil)
            check("bad token is rejected", PairingInvite.parse(link.replacingOccurrences(of: token, with: "omb_pair_short")) == nil)

            let manual = try? PairingInvite.manual(address: "192.168.1.8:8787", code: "123456").get()
            check("manual invite parses", manual?.credential == "123456")
            check("manual invite uses the typed port", manual?.routes.first?.url == "http://192.168.1.8:8787")

            let bare = try? PairingInvite.manual(address: "mac-studio.local", code: "123456").get()
            check("bare host probes both companion ports", bare?.routes.map(\.port) == [8787, 8810])
            check("invalid manual code is refused", (try? PairingInvite.manual(address: "10.0.0.2", code: "12").get()) == nil)

            let local = CompanionEndpoint.direct(host: "192.168.1.8", port: 8787, priority: 0)!
            let hosted = CompanionEndpoint.make(url: "https://phone.example.com", kind: .hosted, priority: 1)!
            check("a local route may fall back to a protected route",
                  CompanionEndpoint.automaticCandidates([local, hosted]).map(\.url) == [local.url, hosted.url])
            check("a protected route never falls back to cleartext",
                  CompanionEndpoint.automaticCandidates([hosted, local]).map(\.url) == [hosted.url])
            check("hosted routes need https", CompanionEndpoint.make(url: "http://phone.example.com", kind: .hosted, priority: 0) == nil)

            check("standing instructions parse", Bot(json: ["id": "soul", "soul": "Always answer in Chinese."])?.soul == "Always answer in Chinese.")
            check("missing standing instructions read as empty", Bot(json: ["id": "plain"])?.soul == "")
            check("chief role survives a renamed bot", Bot(json: ["id": "chief", "name": "协调员", "chiefOfStaff": true])?.chiefOfStaff == true)
            check("ordinary bot named Chief is not a chief", Bot(json: ["id": "worker", "name": "Chief"])?.chiefOfStaff == false)
            let locationBot = Bot(json: ["id": "places", "computer": "cloud", "tasks": [
                ["threadId": "chosen", "surface": "vm"],
                ["threadId": "automatic", "surface": "browser", "surfaceAuto": true],
                ["threadId": "future", "surface": "new-place"],
            ]])!
            check("conversation and bot locations parse separately", locationBot.computer == .cloud && locationBot.task(threadId: "chosen")?.pinnedLocation == .vm)
            check("automatic pins do not look like a person's choice", locationBot.task(threadId: "automatic")?.surface == .browser && locationBot.task(threadId: "automatic")?.pinnedLocation == nil)
            check("unknown locations are not shown as automatic", locationBot.task(threadId: "future")?.pinnedLocation == .unknown)
            let placeConfig = WorkLocationConfig(json: ["box": ["configured": false], "features": ["browser": false]])
            check("known unavailable locations are explained", placeConfig.unavailableReason(for: .cloud, bot: locationBot, instance: nil) != nil && placeConfig.unavailableReason(for: .browser, bot: locationBot, instance: nil) != nil)
            check("missing availability is not mistaken for unavailable", WorkLocationConfig(json: [:]).unavailableReason(for: .vm, bot: locationBot, instance: nil) == nil)

            let imageClient = ApiClient(baseURL: "https://computer.example.com", token: nil)
            let imageURL = "https://computer.example.com/api/attachments/qr-code.png"
            check("remote filesystem images use the attachment route",
                  (try? imageClient.bytesURL("/home/maus/.openmausbot/attachments/qr-code.png"))?.absoluteString == imageURL)
            check("bare image filenames use the attachment route",
                  (try? imageClient.bytesURL("qr-code.png"))?.absoluteString == imageURL)
            check("attachment API paths stay unchanged",
                  (try? imageClient.bytesURL("/api/attachments/qr-code.png"))?.absoluteString == imageURL)
            check("same-origin image URLs stay unchanged",
                  (try? imageClient.bytesURL(imageURL))?.absoluteString == imageURL)
            check("message file routes keep their query",
                  (try? imageClient.bytesURL("/api/threads/t/messages/m/image?size=full"))?.query == "size=full")
            check("foreign image origins are refused",
                  (try? imageClient.bytesURL("https://other.example.com/api/attachments/qr-code.png")) == nil)

            let cardJSON: JSON = [
                "title": "Run the tests?",
                "options": ["Allow", "Deny"],
                "requestId": "req-1",
                "requestType": "permission",
                "tool": "Bash",
            ]
            let card = Card(json: cardJSON)
            check("card parses", card?.title == "Run the tests?" && card?.needsAnswer == true)
            check("card is an approval", card?.isApproval == true)
            check("allow maps to allow", Card.behavior(for: "Allow") == "allow")
            check("deny maps to deny", Card.behavior(for: "Don't allow") == "deny")
            check("Chinese verdicts map to protocol values", Card.behavior(for: "允许") == "allow" && Card.behavior(for: "拒绝") == "deny")
            check("an option maps to answer", Card.behavior(for: "Option B") == "answer")

            let messageJSON: JSON = [
                "id": "m1",
                "role": "bot",
                "kind": "text",
                "text": "hello",
                "createdAt": 1_700_000_000_000,
                "unknownField": ["ignored": true],
            ]
            let message = Message(json: messageJSON)
            check("tolerant message parse", message?.text == "hello" && message?.card == nil)
            let inline = try? AttributedString(
                markdown: "**粗体** and `code`",
                options: AttributedString.MarkdownParsingOptions(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
            let emphasized = inline?.runs.contains { run in
                run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true
            } ?? false
            let code = inline?.runs.contains { run in run.inlinePresentationIntent?.contains(.code) == true } ?? false
            check("inline markdown keeps bold and code", emphasized && code)

            let markdownReply = MarkdownRenderer.render("# 标题\n\n第一段 🎉 **重点** [链接](https://example.com)\n\n第二段内容")
            check("markdown renders headings, links and emphasis", markdownReply?.html.contains("<h1>标题</h1>") == true && markdownReply?.html.contains("<strong>重点</strong>") == true && markdownReply?.html.contains("href=\"https://example.com\"") == true)
            let tableReply = MarkdownRenderer.render("- 外层\n  - 内层\n\n| 名称 | 结果 |\n| --- | --- |\n| 检查 | 通过 |")
            check("markdown renders nested lists and tables", tableReply?.html.contains("<table>") == true && tableReply?.html.components(separatedBy: "<ul>").count == 3)
            let mathReply = MarkdownRenderer.render("$x_{i+1} = a*b$\n\n```swift\nlet cost = \"$5\"\n```")
            check("math survives markdown parsing and code remains literal", mathReply?.containsMath == true && mathReply?.html.contains("$x_{i+1} = a*b$") == true && mathReply?.html.contains("let cost = &quot;$5&quot;") == true)
            let multilineMath = MarkdownRenderer.render("$$\nx_{1} = a*b\n$$")
            let codeMath = MarkdownRenderer.render("`$x$`\n\n```\n$y$\n```")
            check("multiline formulas survive while code is excluded", multilineMath?.containsMath == true && multilineMath?.html.contains("x_{1} = a*b") == true && multilineMath?.html.contains("<br") == false && codeMath?.containsMath == false)
            let unsafeReply = MarkdownRenderer.render("<script>alert(1)</script>\n\n[bad](javascript:alert%281%29)")
            check("raw HTML remains visible without executing", unsafeReply?.html.contains("&lt;script&gt;alert(1)&lt;/script&gt;") == true && unsafeReply?.html.contains("<script>") == false && unsafeReply?.html.contains("href=\"javascript:") == false)

            let activityDate = Date(timeIntervalSince1970: 1_700_000_000)
            let activity = Message(id: "tool-1", role: "bot", kind: "activity", text: "", createdAt: activityDate,
                                   tool: ToolRow(json: ["name": "Bash", "ok": true]), turnId: "turn-1", fromName: "Bot A")
            var nextActivity = activity
            nextActivity.id = "tool-2"
            let grouped = TranscriptEntry.group([activity, nextActivity])
            check("consecutive tools collapse into one stable group", grouped.count == 1 && grouped.first?.id == activity.id && grouped.first?.messages.count == 2)
            let reply = Message(id: "reply", role: "bot", text: "Done", createdAt: activityDate)
            check("replies separate activity groups", TranscriptEntry.group([activity, reply, nextActivity]).count == 3)
            var approval = activity
            approval.id = "approval"
            approval.card = card
            check("approval cards stay outside activity groups", !TranscriptEntry.isActivity(approval) && TranscriptEntry.group([activity, approval, nextActivity]).count == 3)
            nextActivity.turnId = "turn-2"
            check("activity groups respect turn boundaries", TranscriptEntry.group([activity, nextActivity]).count == 2)
            nextActivity.turnId = activity.turnId
            nextActivity.fromName = "Bot B"
            check("activity groups respect room senders", TranscriptEntry.group([activity, nextActivity]).count == 2)
            nextActivity.fromName = activity.fromName
            nextActivity.createdAt = activityDate.addingTimeInterval(301)
            let separated = TranscriptEntry.group([activity, nextActivity])
            check("activity groups preserve time separators", separated.count == 2 && separated.last?.showTime == true)
            check("empty transcripts produce no groups", TranscriptEntry.group([]).isEmpty)

            var digest = Message(id: "digest", role: "bot", text: " \n[digest] · no tool activity observed in this turn · reply: hello", createdAt: activityDate)
            check("bot digest summaries are hidden", digest.isDigest)
            digest.role = "user"
            check("user text mentioning digest stays visible", !digest.isDigest)
            digest.role = "bot"
            digest.text = "This reply explains [digest]."
            check("normal replies mentioning digest stay visible", !digest.isDigest)
            digest.kind = "digest"
            check("explicit digest message kinds are hidden", digest.isDigest)
            digest.card = card
            check("digest filtering preserves interactive cards", !digest.isDigest)

            do {
                let storage = ComputerStore.shared
                let fixture = SavedComputer(
                    id: "selfcheck-name-\(UUID().uuidString)", serverName: "Remote computer",
                    routes: [local], activeURL: local.url, hosts: [local.host],
                    allowedKinds: [.lan], allowedLocalURLs: [local.url], lastUsedAt: Date(), pairedAt: Date()
                )
                storage.upsert(fixture)
                defer { storage.remove(fixture.id) }
                try storage.rename(fixture.id, localName: "  工作电脑  ")
                let renamed = storage.computers.first { $0.id == fixture.id }!
                check("computer remark changes only the local name", renamed.displayName == "工作电脑" && renamed.serverName == fixture.serverName && renamed.routes == fixture.routes)
                let decoded = try JSONDecoder().decode(SavedComputer.self, from: JSONEncoder().encode(renamed))
                check("computer remark survives coding", decoded.localName == "工作电脑")
                let refreshed = storage.upsert(fixture.applying(ConnectionMetadata(serverName: "Updated remote", endpoints: [local])))
                check("stale connection updates preserve the local remark", refreshed.displayName == "工作电脑" && refreshed.serverName == "Updated remote")
                try storage.rename(fixture.id, localName: " \n ")
                let cleared = storage.upsert(renamed)
                check("clearing a remark restores the remote name without stale resurrection", cleared.localName == nil && cleared.displayName == fixture.serverName)
                let legacy = try JSONDecoder().decode(SavedComputer.self, from: JSONEncoder().encode(fixture))
                check("old computer records work without a remark", legacy.localName == nil && legacy.displayName == fixture.serverName)
            } catch {
                check("computer remark persistence", false)
            }

            let store = AppStore.shared
            let botJSON: JSON = [
                "id": "selfcheck-bot", "name": "Test Bot", "threadId": "selfcheck-old",
                "tasks": [
                    ["threadId": "selfcheck-old", "title": "Old", "pinned": true, "createdAt": 1_700_000_000_000, "updatedAt": 1_700_000_001_000],
                    ["threadId": "selfcheck-recent", "title": "Recent", "createdAt": 1_700_000_000_000, "updatedAt": 1_700_000_003_000],
                    ["threadId": "selfcheck-created", "title": "Created", "createdAt": 1_700_000_002_000],
                ],
            ]
            let selectionBot = Bot(json: botJSON)!
            store.handle(["kind": "bot", "bot": botJSON])
            store.openFirstConversation()
            check("first bot opens the most recently updated conversation", store.open?.threadId == "selfcheck-recent" && store.open?.title == "Recent")
            store.open(bot: selectionBot, threadId: "selfcheck-old")
            check("explicit conversation selection is preserved", store.open?.threadId == "selfcheck-old")
            store.open(bot: selectionBot)
            check("selecting a bot returns to its latest conversation", store.open?.threadId == "selfcheck-recent")
            store.handle([
                "kind": "message", "threadId": "selfcheck-old",
                "message": ["id": "selfcheck-live", "at": 1_700_000_004_000, "text": "new activity"],
            ])
            if let updatedBot = store.bots.first(where: { $0.id == selectionBot.id }) {
                store.open(bot: updatedBot)
                check("live activity changes the latest conversation", store.open?.threadId == "selfcheck-old")
            } else {
                check("live activity changes the latest conversation", false)
            }
            check("message timestamps use the wire's at field", store.messages("selfcheck-old").first?.createdAt == wireDate(1_700_000_004_000))
            let legacyBot = Bot(json: ["id": "legacy", "threadId": "legacy-default"])!
            check("bots without tasks retain their default thread", legacyBot.latestTask == nil)
            store.open(bot: legacyBot)
            check("opening a legacy bot uses its default thread", store.open?.threadId == "legacy-default")
            let untimedBot = Bot(json: ["id": "untimed", "tasks": [["threadId": "first"], ["threadId": "second"]]])!
            check("missing dates retain the server's task order", untimedBot.latestTask?.threadId == "first")

            store.handle([
                "kind": "message",
                "threadId": "selfcheck-thread",
                "message": ["id": "selfcheck-1", "role": "bot", "kind": "text", "text": "hi", "createdAt": 1_700_000_000_000],
            ])
            check("message frame appends", store.messages("selfcheck-thread").count == 1)
            store.handle([
                "kind": "message.patch",
                "threadId": "selfcheck-thread",
                "message": ["id": "selfcheck-1", "role": "bot", "kind": "text", "text": "hi there"],
            ])
            check("patch frame merges in place", store.messages("selfcheck-thread").first?.text == "hi there")
            store.handle(["kind": "message.patch", "threadId": "selfcheck-thread", "message": ["id": "selfcheck-1", "text": ""]])
            check("an explicit empty patch clears text", store.messages("selfcheck-thread").first?.text == "")
            check("a partial patch keeps the original timestamp", store.messages("selfcheck-thread").first?.createdAt == wireDate(1_700_000_000_000))
            store.handle([
                "kind": "group.deleted",
                "groupId": "selfcheck-room",
            ])
            check("unknown frames are ignored", store.messages("selfcheck-thread").count == 1)

            let keychainId = "selfcheck-\(UUID().uuidString)"
            let wrote = Keychain.setToken("token-value", for: keychainId)
            check("keychain write", wrote)
            check("keychain read", Keychain.token(for: keychainId) == "token-value")
            Keychain.removeToken(for: keychainId)
            check("keychain delete", Keychain.token(for: keychainId) == nil)
        }

        if command == "all" || command == "pair" || command == "stream" || command == "chat" {
            guard let url = value(for: "--url", in: arguments),
                  let token = value(for: "--token", in: arguments) ?? value(for: "--credential", in: arguments)
            else {
                print("usage: --selfcheck pair|stream|chat --url http://127.0.0.1:8787 --credential <pair token or 6 digits>")
                return 2
            }
            let client = ApiClient(baseURL: url, token: nil)
            var pairedToken: String?
            if command == "pair" || command == "all" {
                do {
                    let health = try await client.health()
                    check("health answers as openmausbot", health.str("app") == "openmausbot")
                    let result = try await client.pair(credential: token, serverNameHint: nil, pairRequestId: UUID().uuidString, timeout: 8)
                    check("pair returns a device token", !result.token.isEmpty)
                    pairedToken = result.token
                } catch {
                    check("pair succeeds (\(error.localizedDescription))", false)
                }
            }
            if command == "chat" || command == "all" {
                let auth = ApiClient(baseURL: url, token: pairedToken ?? token)
                do {
                    let answer = try await auth.botsAndGroups()
                    let bots = answer.objArray("bots").compactMap(Bot.init(json:))
                    check("bot list parses", !bots.isEmpty)
                    if let bot = bots.first {
                        let text = "hello from selfcheck"
                        _ = try await auth.post("/api/bots/\(bot.id)/messages", body: ["threadId": bot.threadId, "text": text, "clientId": "selfcheck-1"])
                        let page = try await auth.threadMessages(threadId: bot.threadId, limit: 50)
                        let messages = page.objArray("messages").compactMap { Message(json: $0) }
                        check("sent message reads back", messages.contains { $0.text == text })
                    }
                } catch {
                    check("chat round trip (\(error.localizedDescription))", false)
                }
            }
            if command == "stream" || command == "all" {
                let auth = ApiClient(baseURL: url, token: pairedToken ?? token)
                var kinds: [String] = []
                do {
                    for try await frame in auth.eventStream(lastEventId: nil) {
                        kinds.append(frame.json.str("kind") ?? "?")
                        if kinds.contains("hello") { break }
                    }
                    check("event stream says hello", kinds.contains("hello"))
                } catch {
                    check("event stream opens (\(error.localizedDescription))", false)
                }
            }
        }

        if command == "app" {
            let invite: PairingInvite
            if let link = value(for: "--link", in: arguments), let parsed = PairingInvite.parse(link) {
                invite = parsed
            } else if let url = value(for: "--url", in: arguments),
                  let credential = value(for: "--credential", in: arguments),
                  let route = CompanionEndpoint.make(url: url, kind: .lan, priority: 0) {
                invite = PairingInvite(
                    routes: [route],
                    token: PairingInvite.isValidToken(credential) ? credential : nil,
                    code: PairingInvite.isValidCode(credential) ? credential : nil,
                    serverName: "Selfcheck Studio"
                )
            } else {
                print("usage: --selfcheck app --url http://127.0.0.1:8799 --credential 123456")
                return 2
            }
            let store = AppStore.shared
            do {
                let saved = try await store.pair(with: invite)
                check("app pairs and saves the computer", store.computers.contains { $0.id == saved.id })
                check("app stores the device token", Keychain.token(for: saved.id) != nil)
                let online = await waitUntil(store) { $0.connection.isOnline }
                check("app reaches the computer", online)
                check("app lists bots", !store.bots.isEmpty)
                check("app seeds the conversation from the bot list", !store.messages("thread-main").isEmpty)
                if let bot = store.bots.first {
                    if arguments.contains("--mock-locations") {
                        var selectionBot = bot
                        if let main = selectionBot.tasks.firstIndex(where: { $0.threadId == "thread-main" }),
                           let other = selectionBot.tasks.firstIndex(where: { $0.threadId == "thread-other" }) {
                            selectionBot.tasks[main].updatedAt = wireDate(1_700_000_050_000)
                            selectionBot.tasks[other].updatedAt = wireDate(1_700_000_100_000)
                            store.handle([
                                "kind": "message", "threadId": "thread-other",
                                "message": ["id": "msg-other-2", "role": "bot", "text": "最新的回复", "createdAt": 1_700_000_100_000],
                            ])
                            store.open(bot: selectionBot)
                            check("app selects the latest conversation instead of the default", store.open?.threadId == "thread-other" && store.open?.title == "另一个对话")
                            let loading = await waitUntil(store) { $0.threads["thread-other"]?.loading == true }
                            store.handle([
                                "kind": "message.patch", "threadId": "thread-other",
                                "message": ["id": "msg-other-2", "text": "实时更新的回复"],
                            ])
                            let loaded = await waitUntil(store) { $0.messages("thread-other").contains { $0.id == "msg-other-1" } }
                            check("opening a conversation loads history after a live message", loaded && store.messages("thread-other").filter { $0.id == "msg-other-2" }.count == 1)
                            check("a live update during history loading is retained", loading && store.messages("thread-other").first { $0.id == "msg-other-2" }?.text == "实时更新的回复")
                            store.open(bot: selectionBot, threadId: "thread-main")
                            check("app can still open an older conversation explicitly", store.open?.threadId == "thread-main")
                            store.open(bot: selectionBot)
                            check("selecting the bot again opens the latest conversation", store.open?.threadId == "thread-other")
                        } else {
                            check("mock provides both conversations", false)
                        }
                    }
                    store.open(bot: bot)
                    check("app opens a real thread", store.open?.threadId == "thread-main")
                    store.send(text: "app selfcheck", attachments: [])
                    let replied = await waitUntil(store) { conversation in
                        conversation.messages("thread-main").contains { $0.isBot && $0.text.contains("app selfcheck") }
                    }
                    check("reply arrives over the event stream", replied)
                    if let cardMessage = store.messages("thread-main").last(where: { $0.card?.needsAnswer == true }),
                       let card = cardMessage.card {
                        store.respond(threadId: "thread-main", card: card, answer: "允许")
                        let settled = await waitUntil(store) { conversation in
                                conversation.messages("thread-main").first { $0.id == cardMessage.id }?.card?.answered == "allow"
                        }
                        check("card answer settles", settled)
                    } else {
                        check("approval card arrives in the transcript", false)
                    }

                    if arguments.contains("--mock-locations") {
                        store.setWorkLocation(botId: bot.id, threadId: "thread-main", location: .vm)
                        check("location update blocks sending immediately", store.updatingLocations.contains("thread-main"))
                        let previousCount = store.messages("thread-main").count
                        store.send(text: "must wait for location")
                        check("a send cannot race the location update", store.messages("thread-main").count == previousCount && store.lastError != nil)
                        store.lastError = nil
                        let pinned = await waitUntil(store) {
                            !$0.updatingLocations.contains("thread-main") && $0.bots.first?.task(threadId: "thread-main")?.pinnedLocation == .vm
                        }
                        check("location is saved for the conversation", pinned)
                        try? await store.refreshAll()
                        check("location survives a fresh server snapshot", store.bots.first?.task(threadId: "thread-main")?.pinnedLocation == .vm)
                        check("another conversation keeps its automatic location", store.bots.first?.task(threadId: "thread-other")?.surfaceAuto == true)
                        store.send(text: "location selfcheck")
                        let routed = await waitUntil(store) { $0.messages("thread-main").contains { $0.text == "mock location: vm" } }
                        check("the next message reaches the selected location", routed)
                        store.setWorkLocation(botId: bot.id, threadId: "thread-other", location: .browser)
                        let explicit = await waitUntil(store) {
                            !$0.updatingLocations.contains("thread-other") && $0.bots.first?.task(threadId: "thread-other")?.pinnedLocation == .browser
                        }
                        check("an automatic location can be pinned explicitly", explicit)
                        store.setWorkLocation(botId: bot.id, threadId: "thread-main", location: nil)
                        let cleared = await waitUntil(store) {
                            !$0.updatingLocations.contains("thread-main") && $0.bots.first?.task(threadId: "thread-main")?.surface == nil
                        }
                        check("following the bot clears only this conversation's pin", cleared && store.bots.first?.task(threadId: "thread-other")?.pinnedLocation == .browser)
                        store.setWorkLocation(botId: bot.id, threadId: "thread-busy", location: .vm)
                        let busyRejected = await waitUntil(store) { !$0.updatingLocations.contains("thread-busy") && $0.lastError != nil }
                        check("a busy conversation keeps its location and shows the error", busyRejected && store.bots.first?.task(threadId: "thread-busy")?.surface == nil)
                        store.lastError = nil
                        store.setWorkLocation(botId: bot.id, threadId: "thread-legacy", location: .vm)
                        let ignored = await waitUntil(store) { !$0.updatingLocations.contains("thread-legacy") && $0.lastError != nil }
                        check("a server that ignores the setting is not reported as successful", ignored && store.bots.first?.task(threadId: "thread-legacy")?.surface == nil)
                        store.lastError = nil
                        store.patchBotProfile(botId: bot.id, fields: ["soul": "先确认，再执行。"])
                        let remembered = await waitUntil(store) { $0.bots.first { $0.id == bot.id }?.soul == "先确认，再执行。" }
                        check("standing instructions save to the bot profile", remembered)
                        try? await store.refreshAll()
                        check("standing instructions survive a refresh", store.bots.first { $0.id == bot.id }?.soul == "先确认，再执行。")
                    }
                    if arguments.contains("--e2e-locations") {
                        store.setWorkLocation(botId: bot.id, threadId: "thread-main", location: .browser)
                        let pinned = await waitUntil(store) {
                            !$0.updatingLocations.contains("thread-main") && $0.bots.first?.task(threadId: "thread-main")?.pinnedLocation == .browser
                        }
                        check("encrypted companion accepts a conversation location", pinned)
                        try? await store.refreshAll()
                        check("encrypted companion reads the saved location", store.bots.first?.task(threadId: "thread-main")?.pinnedLocation == .browser)
                        store.setWorkLocation(botId: bot.id, threadId: "thread-main", location: nil)
                        let cleared = await waitUntil(store) {
                            !$0.updatingLocations.contains("thread-main") && $0.bots.first?.task(threadId: "thread-main")?.surface == nil
                        }
                        check("encrypted companion clears the conversation location", cleared)
                    }

                    store.setModel(botId: bot.id, threadId: "thread-main", selection: ModelSelection(instanceId: "claude", model: "claude-opus-4-1"))
                    let switched = await waitUntil(store) { $0.bots.first { $0.id == bot.id }?.task(threadId: "thread-main")?.modelSelection?.model == "claude-opus-4-1" }
                    check("model switch reaches the conversation", switched)
                    check("conversation model switch preserves bot default", store.bots.first { $0.id == bot.id }?.modelSelection == bot.modelSelection)
                    if var defaultSelection = bot.modelSelection {
                        defaultSelection.effort = "high"
                        store.patchBot(botId: bot.id, fields: ["modelSelection": defaultSelection.json, "keepThreadModels": true])
                        let effortSaved = await waitUntil(store) { $0.bots.first { $0.id == bot.id }?.modelSelection == defaultSelection }
                        check("bot thinking level is saved", effortSaved)
                        defaultSelection.effort = nil
                        store.patchBot(botId: bot.id, fields: ["modelSelection": defaultSelection.json, "keepThreadModels": true])
                        let effortCleared = await waitUntil(store) { $0.bots.first { $0.id == bot.id }?.modelSelection == defaultSelection }
                        check("bot thinking level can return to default", effortCleared)
                        check("bot thinking level preserves conversation model", store.bots.first { $0.id == bot.id }?.task(threadId: "thread-main")?.modelSelection?.model == "claude-opus-4-1")
                    }
                    store.setModel(botId: bot.id, threadId: "thread-main", selection: ModelSelection(instanceId: "claude", model: "reject-model"))
                    let rejected = await waitUntil(store) { $0.lastError == "this thread is busy" }
                    check("model switch shows the server error", rejected)
                    store.lastError = nil

                    store.search("早上")
                    let found = await waitUntil(store) { !$0.searchHits.isEmpty }
                    check("search returns hits", found)

                    await store.newThread(botId: bot.id)
                    check("new thread becomes the open conversation", store.open?.threadId != "thread-main" && store.open != nil)
                }
                store.forget(saved.id)
                check("app forgets the selfcheck computer", !store.computers.contains { $0.id == saved.id })
                check("app removes the device token", Keychain.token(for: saved.id) == nil)
            } catch {
                check("app pairing (\(error.localizedDescription))", false)
            }
        }

        print(failures == 0 ? "PASS" : "FAILED \(failures)")
        return failures == 0 ? 0 : 1
    }

    @MainActor
    private static func waitUntil(_ store: AppStore, seconds: Double = 12, _ condition: (AppStore) -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition(store) { return true }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
        return condition(store)
    }

    private static func value(for flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}
