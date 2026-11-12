import Foundation
import CryptoKit

enum E2EError: LocalizedError {
    case invalidDescriptor, updateRequired, verification, framing, disconnected, removed, timeout
    var errorDescription: String? {
        switch self {
        case .invalidDescriptor: return localized("配对链接里的加密连接信息无效，请从电脑重新复制链接。")
        case .updateRequired: return localized("此电脑要求更新版的加密协议，请更新客户端。")
        case .verification: return localized("无法验证电脑身份，连接已停止。请在电脑设置中重新配对。")
        case .framing: return localized("加密连接数据无效，连接已关闭。")
        case .disconnected: return localized("加密连接已断开。")
        case .removed: return localized("本设备已被远程电脑移除，请重新配对。")
        case .timeout: return localized("加密连接超时，请确认远程电脑在线。")
        }
    }
}

extension Data {
    var b64u: String { base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    init?(b64u: String) {
        guard !b64u.isEmpty, b64u.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { return nil }
        let standard = b64u.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)), data.b64u == b64u else { return nil }
        self = data
    }
    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }
    static func be<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.bigEndian
        return Swift.withUnsafeBytes(of: &value) { Data($0) }
    }
    func uintBE(_ offset: Int, _ length: Int) -> UInt32 {
        self.dropFirst(offset).prefix(length).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

struct E2EDescriptor: Codable, Equatable {
    var v: Int = 1
    var k: String
    var h: String?
    var r: [String]?
    var routes: String?

    init(json: JSON) throws {
        guard let version = json["v"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(),
              version.doubleValue == Double(version.intValue) else { throw E2EError.invalidDescriptor }
        if version.intValue > 1 { throw E2EError.updateRequired }
        guard version.intValue == 1, let key = json["k"] as? String,
              let data = Data(b64u: key), data.count == 65,
              (try? P256.KeyAgreement.PublicKey(x963Representation: data)) != nil else { throw E2EError.invalidDescriptor }
        k = key
        if json["h"] != nil || json["r"] != nil {
            guard let host = json["h"] as? String, Data(b64u: host)?.count == 16,
                  let relays = json["r"] as? [String], (1...4).contains(relays.count),
                  relays.allSatisfy({ $0.range(of: "^relay[1-9][0-9]?\\.openmausbot\\.com$", options: .regularExpression) != nil }) else { throw E2EError.invalidDescriptor }
            h = host; r = relays
        }
        if let route = json["routes"] {
            guard let value = route as? String, ["local", "any"].contains(value) else { throw E2EError.invalidDescriptor }
            routes = value
        }
    }
    init(encoded: String) throws {
        guard encoded.utf8.count <= 1024, let data = Data(b64u: encoded), let json = jsonObject(data) else { throw E2EError.invalidDescriptor }
        try self.init(json: json)
    }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        var json: JSON = ["v": try fields.decode(Int.self, forKey: .v), "k": try fields.decode(String.self, forKey: .k)]
        if fields.contains(.h) { json["h"] = try fields.decode(String.self, forKey: .h) }
        if fields.contains(.r) { json["r"] = try fields.decode([String].self, forKey: .r) }
        if fields.contains(.routes) { json["routes"] = try fields.decode(String.self, forKey: .routes) }
        try self.init(json: json)
    }
    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try! encoder.encode(self)).b64u
    }
    var publicKey: Data { Data(b64u: k)! }
    func psk(credential: String) -> Data {
        let digest = Data(SHA256.hash(data: Data(credential.utf8)))
        let keyId = Data(SHA256.hash(data: publicKey).prefix(16))
        return NoiseState.hmac(digest, Data("omb-e2e psk v1".utf8) + keyId)
    }
    func admission(credential: String) -> Data? {
        guard let h, let hostId = Data(b64u: h) else { return nil }
        return NoiseState.hmac(Data(SHA256.hash(data: Data(credential.utf8))), Data("omb-relay admission v1".utf8) + hostId)
    }
    func accepting(_ next: E2EDescriptor?) throws -> E2EDescriptor {
        guard let next else { return self }
        let check = NoiseState.hmac(publicKey, Data("omb-pin-check".utf8))
        guard HMAC<SHA256>.isValidAuthenticationCode(check, authenticating: Data("omb-pin-check".utf8), using: SymmetricKey(data: next.publicKey)) else { throw E2EError.verification }
        return next
    }
}

struct NoiseCipher {
    var key: Data
    var nonce: UInt64 = 0
    mutating func seal(_ data: Data, aad: Data = Data()) throws -> Data {
        guard nonce < (1 << 32) else { throw E2EError.disconnected }
        let n = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + Data.be(nonce))
        let box = try AES.GCM.seal(data, using: SymmetricKey(data: key), nonce: n, authenticating: aad)
        nonce += 1
        return box.ciphertext + box.tag
    }
    mutating func open(_ data: Data, aad: Data = Data()) throws -> Data {
        guard data.count >= 16, data.count <= 65_535, nonce < (1 << 32) else { throw E2EError.framing }
        let n = try AES.GCM.Nonce(data: Data(repeating: 0, count: 4) + Data.be(nonce))
        let box = try AES.GCM.SealedBox(nonce: n, ciphertext: data.dropLast(16), tag: data.suffix(16))
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        nonce += 1
        return plain
    }
}

struct NoiseState {
    var h: Data
    var ck: Data
    var cipher: NoiseCipher?

    init(remote: Data, transport: UInt8) {
        var name = Data("Noise_NKpsk0_P256_AESGCM_SHA256".utf8)
        name.append(Data(repeating: 0, count: 32 - name.count))
        h = name; ck = name
        mixHash(Data("omb-e2e/1".utf8) + Data([0, transport]))
        mixHash(remote)
    }
    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    static func hkdf(_ key: Data, _ input: Data, count: Int) -> [Data] {
        let temp = hmac(key, input)
        var previous = Data(), outputs: [Data] = []
        for i in 1...count {
            previous = hmac(temp, previous + Data([UInt8(i)]))
            outputs.append(previous)
        }
        return outputs
    }
    mutating func mixHash(_ bytes: Data) { h = Data(SHA256.hash(data: h + bytes)) }
    mutating func mixKey(_ input: Data) {
        let keys = Self.hkdf(ck, input, count: 2)
        ck = keys[0]; cipher = NoiseCipher(key: keys[1])
    }
    mutating func mixPSK(_ input: Data) {
        let keys = Self.hkdf(ck, input, count: 3)
        ck = keys[0]; mixHash(keys[1]); cipher = NoiseCipher(key: keys[2])
    }
    mutating func seal(_ data: Data) throws -> Data {
        let result = try cipher!.seal(data, aad: h)
        mixHash(result)
        return result
    }
    mutating func open(_ data: Data) throws -> Data {
        let result = try cipher!.open(data, aad: h)
        mixHash(data)
        return result
    }
    func split() -> (NoiseCipher, NoiseCipher) {
        let keys = Self.hkdf(ck, Data(), count: 2)
        return (NoiseCipher(key: keys[0]), NoiseCipher(key: keys[1]))
    }
}

struct NoisePhoneHandshake {
    var state: NoiseState
    let ephemeral: P256.KeyAgreement.PrivateKey
    let conn: String
    var message1: Data

    init(descriptor: E2EDescriptor, credential: String, transport: UInt8,
         ephemeral: P256.KeyAgreement.PrivateKey = .init(), payload: Data? = nil) throws {
        self.ephemeral = ephemeral
        let bytes = payload ?? jsonData(["v": 1, "conn": Data.randomBytes(16).b64u, "app": "macOS/\(AppInfo.version)"])!
        guard let conn = jsonObject(bytes)?.str("conn") else { throw E2EError.framing }
        self.conn = conn
        state = NoiseState(remote: descriptor.publicKey, transport: transport)
        state.mixPSK(descriptor.psk(credential: credential))
        let pub = ephemeral.publicKey.x963Representation
        state.mixHash(pub); state.mixKey(pub)
        let remote = try P256.KeyAgreement.PublicKey(x963Representation: descriptor.publicKey)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: remote)
        state.mixKey(shared.withUnsafeBytes { Data($0) })
        message1 = pub + (try state.seal(bytes))
    }
    mutating func finish(_ message: Data) throws -> (NoiseCipher, NoiseCipher) {
        do {
            guard (81...593).contains(message.count) else { throw E2EError.verification }
            let pub = Data(message.prefix(65))
            let remote = try P256.KeyAgreement.PublicKey(x963Representation: pub)
            state.mixHash(pub); state.mixKey(pub)
            let shared = try ephemeral.sharedSecretFromKeyAgreement(with: remote)
            state.mixKey(shared.withUnsafeBytes { Data($0) })
            let payload = try state.open(Data(message.dropFirst(65)))
            guard let json = jsonObject(payload), let version = json["v"] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                  json.str("conn") == conn else { throw E2EError.verification }
            return state.split()
        } catch { throw E2EError.verification }
    }
}
