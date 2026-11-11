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

            let store = AppStore.shared
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

                    store.setModel(botId: bot.id, selection: ModelSelection(instanceId: "claude", model: "claude-opus-4-1"))
                    let switched = await waitUntil(store) { $0.bots.first { $0.id == bot.id }?.modelSelection?.model == "claude-opus-4-1" }
                    check("model switch reaches the bot", switched)

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
