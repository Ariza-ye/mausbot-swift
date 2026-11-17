import AppKit
import CommonCrypto
import Foundation

@MainActor
final class PrivateDesktop: ObservableObject {
    @Published var image: NSImage?
    @Published var error: String?
    @Published var connected = false
    @Published var working = false
    @Published private(set) var releasing = false
    @Published private(set) var controlling = false

    private let api: ApiClient
    private let botId: String
    private let threadId: String
    private let lease = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private var socket: URLSessionWebSocketTask?
    private var receiver: Task<Void, Never>?
    private var input = Data()
    private var held = false
    private var stopping = false
    private var generation = 0
    private var outbound: Task<Void, Never>?
    private var width = 0
    private var height = 0
    private var pixels = Data()

    init(api: ApiClient, botId: String, threadId: String) {
        self.api = api; self.botId = botId; self.threadId = threadId
    }

    private func path(_ suffix: String, extra: [URLQueryItem] = []) -> String {
        var parts = URLComponents()
        parts.queryItems = [URLQueryItem(name: "threadId", value: threadId)] + extra
        return "/api/bots/\(botId)/\(suffix)?\(parts.percentEncodedQuery ?? "")"
    }

    func start() async {
        guard !working && !held && !releasing else { return }
        working = true; stopping = false; error = nil
        generation += 1
        let attempt = generation
        defer { working = false }
        do {
            let result = try await api.post(path("computer/control"), body: ["action": "take", "controlLeaseId": lease])
            guard result.bool("owned") == true, result.bool("acquired") == true else {
                throw failure("桌面已被其他用户控制")
            }
            held = true
            controlling = true
            guard !stopping else { await stop(); return }
            let join = try await api.post(path("local-computer/join", extra: [URLQueryItem(name: "controlLeaseId", value: lease)]))
            let address: String
            let password: String
            if let raw = join.str("joinUrl"), let url = URLComponents(string: raw),
               raw.hasPrefix("/vps-viewer/"), let fragment = url.percentEncodedFragment {
                var fields = URLComponents(); fields.percentEncodedQuery = fragment
                let values = fields.queryItems ?? []
                guard let relay = values.first(where: { $0.name == "path" })?.value,
                      relay.hasPrefix("vps-viewer/"), !relay.contains("..") else { throw failure("桌面连接地址无效") }
                address = "/" + relay
                password = values.first(where: { $0.name == "password" })?.value ?? ""
            } else if let relay = join.str("socketPath"), relay.hasPrefix("api/desktop-viewer/local/"), !relay.contains("..") {
                address = "/" + relay
                password = join.str("password") ?? ""
            } else { throw failure("服务端没有返回可用的私有桌面连接") }
            guard !stopping else { await stop(); return }
            guard let url = URL(string: api.baseURL + address) else { throw failure("桌面连接地址无效") }
            var request = URLRequest(url: url)
            if let token = api.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            request = try await api.prepare(request)
            guard !stopping, generation == attempt else { await stop(); return }
            guard var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false) else { throw failure("桌面连接地址无效") }
            components.scheme = components.scheme == "https" ? "wss" : "ws"
            request.url = components.url
            let socket = URLSession.shared.webSocketTask(with: request)
            socket.maximumMessageSize = 32 * 1024 * 1024
            self.socket = socket
            socket.resume()
            receiver = Task { [weak self] in
                guard let self else { return }
                do { try await self.run(password: password) }
                catch {
                    guard self.generation == attempt else { return }
                    if !self.stopping { self.error = error.localizedDescription }
                    await self.stop()
                }
            }
        } catch {
            self.error = error.localizedDescription
            await stop()
        }
    }

    func stop() async {
        stopping = true
        generation += 1
        connected = false
        controlling = false
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        outbound?.cancel(); outbound = nil
        receiver = nil
        input.removeAll()
        if held {
            held = false
            releasing = true
            defer { releasing = false }
            do {
                let response = try await api.post(path("computer/control"), body: ["action": "release", "controlLeaseId": lease])
                if response.bool("released") != true { error = localized("无法确认控制权已归还") }
            } catch { self.error = localized("归还控制权失败：%@", error.localizedDescription) }
        }
    }

    private func failure(_ text: String) -> APIError { APIError(status: 0, message: localized(text), body: nil) }

    private func read(_ count: Int) async throws -> Data {
        guard count >= 0, count <= 32 * 1024 * 1024 else { throw failure("桌面数据过大") }
        while input.count < count {
            guard let socket else { throw failure("桌面连接已关闭") }
            switch try await socket.receive() {
            case .data(let data): input.append(data)
            case .string: throw failure("桌面数据格式无效")
            @unknown default: throw failure("桌面数据格式无效")
            }
        }
        let data = Data(input.prefix(count)); input.removeFirst(count); return data
    }

    private func send(_ bytes: Data) async throws {
        guard let socket else { throw failure("桌面连接已关闭") }
        try await socket.send(.data(bytes))
    }

    private func run(password: String) async throws {
        let version = try await read(12)
        guard String(data: version, encoding: .ascii)?.hasPrefix("RFB 003.") == true else { throw failure("不支持的桌面协议") }
        try await send(Data("RFB 003.008\n".utf8))
        let count = Int((try await read(1))[0])
        guard count > 0 else { throw failure("桌面拒绝连接") }
        let types = try await read(count)
        if types.contains(2) {
            try await send(Data([2]))
            let challenge = try await read(16)
            let bytes = Array(password.utf8.prefix(8)) + Array(repeating: UInt8(0), count: max(0, 8 - password.utf8.count))
            let key = bytes.map { value in (0..<8).reduce(UInt8(0)) { ($0 << 1) | ((value >> $1) & 1) } }
            var output = Data(count: 16); var moved = 0
            let status = output.withUnsafeMutableBytes { out in
                challenge.withUnsafeBytes { source in
                    key.withUnsafeBytes { secret in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode), secret.baseAddress, 8, nil, source.baseAddress, 16, out.baseAddress, 16, &moved)
                    }
                }
            }
            guard status == kCCSuccess, moved == 16 else { throw failure("桌面认证失败") }
            try await send(output)
        } else if types.contains(1) { try await send(Data([1])) }
        else { throw failure("不支持的桌面认证方式") }
        guard (try await read(4)).allSatisfy({ $0 == 0 }) else { throw failure("桌面认证失败") }
        try await send(Data([1]))
        let initData = try await read(24)
        width = int16(initData, 0); height = int16(initData, 2)
        let nameLength = int32(initData, 20)
        _ = try await read(nameLength)
        try resize(width, height)
        // 32-bit little-endian true colour, followed by raw and desktop-size encodings.
        try await send(Data([0,0,0,0, 32,24,0,1, 0,255,0,255,0,255, 16,8,0,0,0,0]))
        try await send(Data([2,0,0,2, 0,0,0,0, 255,255,255,33]))
        try await requestFrame(incremental: false)
        connected = true
        while !Task.isCancelled {
            let type = (try await read(1))[0]
            switch type {
            case 0:
                let header = try await read(3)
                let rectangles = int16(header, 1)
                var resized = false
                for _ in 0..<rectangles {
                    let rect = try await read(12)
                    let x = int16(rect, 0), y = int16(rect, 2), w = int16(rect, 4), h = int16(rect, 6)
                    let encoding = Int32(bitPattern: UInt32(int32(rect, 8)))
                    if encoding == -223 { try resize(w, h); resized = true; continue }
                    guard encoding == 0, w > 0, h > 0, x + w <= width, y + h <= height else { throw failure("不支持的桌面画面格式") }
                    let raw = try await read(w * h * 4)
                    pixels.withUnsafeMutableBytes { (target: UnsafeMutableRawBufferPointer) in
                        raw.withUnsafeBytes { (source: UnsafeRawBufferPointer) in
                            for row in 0..<h {
                                target.baseAddress!.advanced(by: ((y + row) * width + x) * 4)
                                    .copyMemory(from: source.baseAddress!.advanced(by: row * w * 4), byteCount: w * 4)
                            }
                        }
                    }
                }
                draw()
                try await requestFrame(incremental: !resized)
            case 2: break
            case 3:
                let header = try await read(7)
                _ = try await read(int32(header, 3))
            default: throw failure("不支持的桌面消息")
            }
        }
    }

    private func resize(_ w: Int, _ h: Int) throws {
        guard w > 0, h > 0, w <= 4096, h <= 4096 else { throw failure("桌面尺寸无效") }
        width = w; height = h; pixels = Data(count: w * h * 4)
    }

    private func draw() {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return }
        image = NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    private func int16(_ d: Data, _ i: Int) -> Int { Int(d[i]) << 8 | Int(d[i+1]) }
    private func int32(_ d: Data, _ i: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(d[i+$1]) } }
    private func u16(_ n: Int) -> [UInt8] { [UInt8((n >> 8) & 255), UInt8(n & 255)] }
    private func requestFrame(incremental: Bool) async throws {
        try await send(Data([3, incremental ? 1 : 0] + u16(0) + u16(0) + u16(width) + u16(height)))
    }
    func pointer(x: Int, y: Int, buttons: UInt8) {
        guard connected, width > 0, height > 0 else { return }
        let data = Data([5, buttons] + u16(max(0, min(width - 1, x))) + u16(max(0, min(height - 1, y))))
        enqueue(data)
    }
    func key(_ value: UInt32, down: Bool) {
        guard connected else { return }
        let data = Data([4, down ? 1 : 0, 0, 0, UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)])
        enqueue(data)
    }
    private func enqueue(_ data: Data) {
        let previous = outbound
        outbound = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            try? await self?.send(data)
        }
    }
}
