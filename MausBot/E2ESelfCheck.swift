import Foundation
import CryptoKit

enum E2ESelfCheck {
    #if DEBUG
    @MainActor
    static func relay(url: URL, descriptor: E2EDescriptor, token: String) async -> Int32 {
        do {
            let connection = try await E2EConnection.referenceRelay(url: url, descriptor: descriptor, credential: token)
            defer { connection.close() }
            let origin = connection.referenceOrigin!
            var request = URLRequest(url: URL(string: origin.baseURL + "/api/bots")!)
            request.setValue(origin.secret, forHTTPHeaderField: "X-OMB-Loopback")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, jsonObject(data)?.objArray("bots").isEmpty == false else { throw E2EError.framing }
            print("PASS relay admission → ready → Noise relay prologue → encrypted HTTP through official proxy")
            return 0
        } catch { print("FAIL relay: \(error)"); return 1 }
    }
    #endif
    @MainActor
    static func upgrade(baseURL: String, token: String) async -> Int32 {
        guard let route = CompanionEndpoint.make(url: baseURL, kind: .lan, priority: 0) else { return 2 }
        let id = "selfcheck-upgrade-" + UUID().uuidString
        let saved = SavedComputer(id: id, serverName: "Legacy migration fixture", routes: [route], activeURL: route.url,
                                  hosts: [], allowedKinds: [.lan], allowedLocalURLs: [route.url], lastCursor: nil,
                                  deviceId: nil, lastUsedAt: Date(), pairedAt: Date())
        let storage = ComputerStore.shared
        guard storage.setToken(token, for: id) else { return 1 }
        storage.upsert(saved); storage.selectedId = id
        let store = AppStore.shared
        store.start()
        for _ in 0..<150 {
            if store.connection.isOnline || store.connection.phase == .error { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let success = store.connection.isOnline && store.computer?.e2e != nil
        print(success ? "PASS legacy pairing upgraded, transport key pinned, encrypted stream online" : "FAIL migration: \(store.connection.detail)")
        store.forget(id)
        return success ? 0 : 1
    }

    @MainActor
    static func run(baseURL: String?) async -> Int32 {
        var failures = 0
        func check(_ label: String, _ valid: Bool) {
            print(valid ? "ok   \(label)" : "FAIL \(label)")
            if !valid { failures += 1 }
        }
        do {
            guard let url = Bundle.main.url(forResource: "e2e-vectors", withExtension: "json"),
                  let vectors = jsonObject(try Data(contentsOf: url)),
                  let input = vectors.obj("inputs"), let v1 = vectors.obj("V1") else { throw E2EError.framing }
            let descriptor = try E2EDescriptor(json: ["v": 1, "k": v1.str("transportPublicB64u")!, "h": v1.str("hostIdB64u")!, "r": ["relay1.openmausbot.com"]])
            for credential in v1.objArray("credentials") {
                check("V1 PSK \(credential.str("name")!)", descriptor.psk(credential: credential.str("token")!) == hex(credential.str("psk")!))
                check("V1 admission \(credential.str("name")!)", descriptor.admission(credential: credential.str("token")!) == hex(credential.str("adm")!))
            }
            let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(input.str("phoneEphemeralPrivate")!))
            for name in ["V2", "V3"] {
                let vector = vectors.obj(name)!
                let credential = input.str(name == "V2" ? "deviceToken" : "pairingToken")!
                var handshake = try NoisePhoneHandshake(descriptor: descriptor, credential: credential, transport: UInt8(vector.int("transport")!), ephemeral: ephemeral, payload: hex(vector.str("payload1")!))
                check("\(name) message 1 byte-for-byte", handshake.message1 == hex(vector.str("message1")!))
                let keys = try handshake.finish(hex(vector.str("message2")!))
                check("\(name) transport keys", keys.0.key == hex(vector.str("kPc")!) && keys.1.key == hex(vector.str("kCp")!))
                check("\(name) handshake hash", handshake.state.h == hex(vector.str("handshakeHash")!))
                var bad = try NoisePhoneHandshake(descriptor: descriptor, credential: credential, transport: UInt8(vector.int("transport")!), ephemeral: ephemeral, payload: hex(vector.str("payload1")!))
                var tampered = hex(vector.str("message2")!); tampered[tampered.count - 1] ^= 1
                do { _ = try bad.finish(tampered); check("\(name) rejects forged peer", false) }
                catch { check("\(name) rejects forged peer", true) }
            }
            let v4 = vectors.obj("V4")!
            var pc = NoiseCipher(key: hex(v4.str("kPc")!)), cp = NoiseCipher(key: hex(v4.str("kCp")!))
            for record in v4.objArray("records") {
                let frame = hex(record.str("frame")!)
                let actual = try record.str("direction") == "pc" ? pc.seal(frame) : cp.seal(frame)
                check("V4 \(record.str("direction")!) nonce \(record.int("n")!)", actual == hex(record.str("record")!))
            }
            let encoded = descriptor.encoded
            check("descriptor round trip", try E2EDescriptor(encoded: encoded) == descriptor)
            let swapped = try E2EDescriptor(json: ["v": 1, "k": P256.KeyAgreement.PrivateKey().publicKey.x963Representation.b64u])
            do { _ = try descriptor.accepting(swapped); check("pinned key never replaced", false) }
            catch { check("pinned key never replaced", true) }
            check("strict base64 rejects padding", Data(b64u: "YQ==") == nil)
            do { _ = try E2EDescriptor(json: ["v": 1, "k": descriptor.k, "h": descriptor.h!, "r": ["attacker.example"]]); check("relay allowlist", false) }
            catch { check("relay allowlist", true) }
            if let baseURL {
                let api = ApiClient(baseURL: baseURL, token: input.str("deviceToken"), e2e: descriptor)
                let health = try await api.get("/api/health")
                check("official Node E2E origin HTTP", health.bool("ok"))
                let payload = Data((0..<(3 * 1024 * 1024)).map { UInt8($0 % 251) })
                // Binary bodies exercise both direction windows beyond 2 MiB.
                let local = try await E2EConnection.localOrigin(baseURL: baseURL, descriptor: descriptor, credential: input.str("deviceToken")!)
                let reused = try await E2EConnection.localOrigin(baseURL: baseURL, descriptor: descriptor, credential: input.str("deviceToken")!)
                check("encrypted session reused", local.baseURL == reused.baseURL && local.secret == reused.secret)
                var request = URLRequest(url: URL(string: local.baseURL + "/upload")!)
                request.httpMethod = "POST"; request.httpBody = payload
                request.setValue(local.secret, forHTTPHeaderField: "X-OMB-Loopback")
                let (reply, _) = try await URLSession.shared.data(for: request)
                let uploaded = jsonObject(reply)
                check("3 MiB upload crosses yamux window", uploaded?.int("bytes") == payload.count)
                check("upload bytes authenticated intact", uploaded?.str("sha256") == Data(SHA256.hash(data: payload)).map { String(format: "%02x", $0) }.joined())
                let download = try await api.bytes("/bytes?n=3145728")
                check("3 MiB download crosses yamux window", download == payload)
                async let first = api.get("/wait?ms=80")
                async let second = api.get("/wait?ms=20")
                let parallel = try await (first, second)
                check("concurrent HTTP streams", parallel.0.bool("waited") && parallel.1.bool("waited"))
                var streamRequest = URLRequest(url: URL(string: baseURL + "/sse?events=3&size=64&gapMs=10")!)
                streamRequest = try await api.prepare(streamRequest)
                let (bytes, _) = try await URLSession.shared.bytes(for: streamRequest)
                var ids = 0
                for try await line in bytes.lines { if line.hasPrefix("id:") { ids += 1 } }
                check("SSE over encrypted stream", ids == 3)
                // The loopback listener must refuse a browser or another local process.
                let untrusted = URLSession(configuration: .ephemeral)
                defer { untrusted.invalidateAndCancel() }
                do {
                    _ = try await untrusted.data(from: URL(string: local.baseURL + "/api/health")!)
                    check("unauthorized loopback request rejected", false)
                } catch { check("unauthorized loopback request rejected", true) }
                #if DEBUG
                var swappedURL = URLComponents(string: baseURL)!
                swappedURL.scheme = "ws"; swappedURL.path = "/test/wrong-key"
                do {
                    let connection = try await E2EConnection.referenceRelay(url: swappedURL.url!, descriptor: descriptor,
                        credential: input.str("deviceToken")!, relayed: false)
                    connection.close()
                    check("official wrong-key server rejected", false)
                } catch E2EError.verification { check("official wrong-key server rejected", true) }
                #endif
            }
        } catch {
            print("FAIL E2E: \(error)"); failures += 1
        }
        E2EConnection.closeAll()
        print(failures == 0 ? "PASS E2E" : "FAILED E2E \(failures)")
        return failures == 0 ? 0 : 1
    }
    private static func hex(_ value: String) -> Data {
        var data = Data(), index = value.startIndex
        while index < value.endIndex {
            let end = value.index(index, offsetBy: 2)
            data.append(UInt8(value[index..<end], radix: 16)!)
            index = end
        }
        return data
    }
}
