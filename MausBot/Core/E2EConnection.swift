import Foundation
import Network
import CryptoKit

struct E2ELocalOrigin {
    var baseURL: String
    var secret: String
}

@MainActor
final class E2EConnection {
    private static var sessions: [String: Task<E2EConnection, Error>] = [:]
    let secret = Data.randomBytes(32).b64u
    private var listener: NWListener?
    private var socket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var reader: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var sender: Task<Void, Never>?
    private var tx: NoiseCipher?
    private var rx: NoiseCipher?
    private var outbox: [Data] = []
    private var queuedBytes = 0
    private var streams: [UInt32: Pipe] = [:]
    private var nextID: UInt32 = 1
    private var lastPing: Date?
    private var pingID: UInt32 = 0
    private var origin: E2ELocalOrigin?
    private(set) var closed = false
    private var terminalError: E2EError?
    private var relayed = false

    private final class Pipe {
        let tcp: NWConnection
        var sendWindow = 256 * 1024
        var recvWindow = 2 * 1024 * 1024
        var consumed = 0
        var acknowledged = false
        var localFIN = false
        var remoteFIN = false
        var reading = false
        init(_ tcp: NWConnection) { self.tcp = tcp }
    }

    static func localOrigin(baseURL: String, descriptor: E2EDescriptor, credential: String) async throws -> E2ELocalOrigin {
        let cacheKey = baseURL + ":" + descriptor.encoded + ":" + Data(SHA256.hash(data: Data(credential.utf8))).b64u
        if let existing = sessions[cacheKey] {
            do {
                let connection = try await existing.value
                if let error = connection.terminalError { throw error }
                if !connection.closed, let origin = connection.origin { return origin }
            } catch { sessions.removeValue(forKey: cacheKey); throw error }
        }
        let task = Task { @MainActor in
            let connection = E2EConnection()
            try await connection.connect(baseURL: baseURL, descriptor: descriptor, credential: credential)
            return connection
        }
        sessions[cacheKey] = task
        do {
            let connection = try await task.value
            return connection.origin!
        } catch {
            sessions.removeValue(forKey: cacheKey)
            throw error
        }
    }

    static func closeAll() {
        for task in sessions.values {
            task.cancel()
            Task { if let connection = try? await task.value { connection.close() } }
        }
        sessions.removeAll()
    }

    #if DEBUG
    static func referenceRelay(url: URL, descriptor: E2EDescriptor, credential: String, relayed: Bool = true) async throws -> E2EConnection {
        let connection = E2EConnection()
        do {
            try await connection.handshake(url: url, relayed: relayed, descriptor: descriptor, credential: credential)
            try await connection.listen()
            connection.startReceiving()
            return connection
        } catch { connection.close(); throw error }
    }
    var referenceOrigin: E2ELocalOrigin? { origin }
    #endif

    private func connect(baseURL: String, descriptor: E2EDescriptor, credential: String) async throws {
        var candidates: [(URL, Bool)] = []
        if var direct = URLComponents(string: baseURL), direct.scheme == "http" {
            direct.scheme = "ws"; direct.path = "/v1/e2e"; direct.query = nil
            if let url = direct.url { candidates.append((url, false)) }
        }
        if descriptor.routes != "local", let nodes = descriptor.r {
            candidates += nodes.compactMap { URL(string: "wss://\($0)/v1/phone").map { ($0, true) } }
        }
        guard !candidates.isEmpty else { throw E2EError.disconnected }
        var last: Error = E2EError.disconnected
        for (url, relay) in candidates {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { @MainActor in
                        try await self.handshake(url: url, relayed: relay, descriptor: descriptor, credential: credential)
                    }
                    group.addTask { @MainActor in
                        try await Task.sleep(nanoseconds: relay ? 20_000_000_000 : 10_000_000_000)
                        self.socket?.cancel(with: .goingAway, reason: nil)
                        throw E2EError.timeout
                    }
                    defer { group.cancelAll() }
                    try await group.next()
                }
                try await listen()
                startReceiving()
                return
            } catch E2EError.verification {
                close(); throw E2EError.verification
            } catch E2EError.removed {
                close(); throw E2EError.removed
            } catch {
                last = error
                socket?.cancel(with: .goingAway, reason: nil)
                session?.invalidateAndCancel()
            }
        }
        close()
        throw last
    }

    private func handshake(url: URL, relayed: Bool, descriptor: E2EDescriptor, credential: String) async throws {
        self.relayed = relayed
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        let session = URLSession(configuration: config, delegate: CompanionSessionDelegate(), delegateQueue: nil)
        self.session = session
        let socket = session.webSocketTask(with: url, protocols: [relayed ? "omb-relay.v1" : "omb-e2e.v1"])
        self.socket = socket
        socket.maximumMessageSize = 70_000
        socket.resume()
        if relayed {
            guard let host = descriptor.h, let admission = descriptor.admission(credential: credential) else { throw E2EError.invalidDescriptor }
            let hello = jsonData(["t": "phone", "v": 1, "hid": host, "adm": admission.b64u])!
            try await socket.send(.string(String(decoding: hello, as: UTF8.self)))
            guard case .string(let text) = try await socket.receive(), jsonObject(text)?.str("t") == "ready" else { throw E2EError.framing }
        }
        var handshake = try NoisePhoneHandshake(descriptor: descriptor, credential: credential, transport: relayed ? 1 : 2)
        try await socket.send(.data(handshake.message1))
        let message: URLSessionWebSocketTask.Message
        do { message = try await socket.receive() }
        catch {
            if !relayed, socket.closeCode.rawValue == 4001 { throw E2EError.removed }
            throw error
        }
        guard case .data(let response) = message else { throw E2EError.verification }
        let ciphers = try handshake.finish(response)
        tx = ciphers.0; rx = ciphers.1
    }

    private func listen() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resolved = false
            listener.stateUpdateHandler = { state in
                Task { @MainActor in
                    guard !resolved else { return }
                    switch state {
                    case .ready:
                        resolved = true
                        guard let port = listener.port else { continuation.resume(throwing: E2EError.disconnected); return }
                        self.origin = E2ELocalOrigin(baseURL: "http://127.0.0.1:\(port.rawValue)", secret: self.secret)
                        continuation.resume()
                    case .failed(let error): resolved = true; continuation.resume(throwing: error)
                    case .cancelled: resolved = true; continuation.resume(throwing: E2EError.disconnected)
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
        }
    }

    private func accept(_ tcp: NWConnection) {
        guard !closed, streams.count < 64, nextID < 0x7fff_ffff else { tcp.cancel(); return }
        tcp.start(queue: .main)
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if !Task.isCancelled { tcp.cancel() }
        }
        readHead(tcp, buffer: Data(), deadline: deadline)
    }

    private func readHead(_ tcp: NWConnection, buffer: Data, deadline: Task<Void, Never>) {
        tcp.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, !self.closed, error == nil, !ended else { tcp.cancel(); deadline.cancel(); return }
                let buffer = buffer + (data ?? Data())
                guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                    guard buffer.count < 16_384 else { tcp.cancel(); deadline.cancel(); return }
                    self.readHead(tcp, buffer: buffer, deadline: deadline)
                    return
                }
                guard range.upperBound <= 16_384 else { tcp.cancel(); deadline.cancel(); return }
                let lines = String(decoding: buffer[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let supplied = lines.dropFirst().first { $0.lowercased().hasPrefix("x-omb-loopback:") }?.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
                guard supplied == self.secret, self.streams.count < 64 else { tcp.cancel(); deadline.cancel(); return }
                deadline.cancel()
                let id = self.nextID; self.nextID += 2
                let pipe = Pipe(tcp)
                self.streams[id] = pipe
                // Keep the per-launch secret on this computer.
                let head = lines.filter { !$0.lowercased().hasPrefix("x-omb-loopback:") }.joined(separator: "\r\n")
                let forwarded = Data((head + "\r\n\r\n").utf8) + buffer[range.upperBound...]
                do {
                    try self.sendFrame(type: 1, flags: 1, id: id, length: 1_835_008)
                    try self.sendData(forwarded, id: id)
                    self.readTCP(id)
                } catch { self.close() }
            }
        }
    }

    private func readTCP(_ id: UInt32) {
        guard let pipe = streams[id], !pipe.reading, !pipe.localFIN, pipe.sendWindow > 0,
              queuedBytes < 1_048_576, !closed else { return }
        pipe.reading = true
        pipe.tcp.receive(minimumIncompleteLength: 1, maximumLength: min(65_507, pipe.sendWindow)) { [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, let pipe = self.streams[id], !self.closed else { return }
                pipe.reading = false
                do {
                    if let data, !data.isEmpty { try self.sendData(data, id: id) }
                    if error != nil { try self.reset(id); return }
                    if ended {
                        pipe.localFIN = true
                        try self.sendFrame(type: 1, flags: 4, id: id, length: 0)
                        self.reap(id)
                    } else { self.readTCP(id) }
                } catch { self.close() }
            }
        }
    }

    private func sendData(_ data: Data, id: UInt32) throws {
        guard let pipe = streams[id], data.count <= pipe.sendWindow else { throw E2EError.framing }
        var offset = 0
        while offset < data.count {
            let size = min(65_507, data.count - offset)
            try sendFrame(type: 0, flags: 0, id: id, length: UInt32(size), payload: data.subdata(in: offset..<(offset + size)))
            offset += size
        }
        pipe.sendWindow -= data.count
    }

    private func sendFrame(type: UInt8, flags: UInt16, id: UInt32, length: UInt32, payload: Data = Data()) throws {
        guard !closed, tx != nil else { throw E2EError.disconnected }
        let plain = Data([0, type]) + Data.be(flags) + Data.be(id) + Data.be(length) + payload
        let record = try tx!.seal(plain)
        outbox.append(record)
        queuedBytes += record.count
        if sender == nil {
            sender = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    while !self.outbox.isEmpty, !self.closed {
                        let frame = self.outbox.removeFirst()
                        try await self.socket!.send(.data(frame))
                        self.queuedBytes -= frame.count
                        if self.queuedBytes < 262_144 {
                            for id in Array(self.streams.keys) { self.readTCP(id) }
                        }
                    }
                    self.sender = nil
                } catch { self.close() }
            }
        }
    }

    private func startReceiving() {
        reader = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled, !self.closed {
                    guard case .data(let record) = try await self.socket!.receive() else { throw E2EError.framing }
                    try self.receiveFrame(self.rx!.open(record))
                }
            } catch {
                if !self.relayed, self.socket?.closeCode.rawValue == 4001 { self.terminalError = .removed }
                self.close()
            }
        }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
                guard let self, !self.closed else { return }
                do {
                    if let sent = self.lastPing, Date().timeIntervalSince(sent) >= 10 { self.close(); return }
                    if self.lastPing == nil {
                        self.pingID &+= 1; self.lastPing = Date()
                        try self.sendFrame(type: 2, flags: 1, id: 0, length: self.pingID)
                    }
                } catch { self.close(); return }
            }
        }
    }

    private func receiveFrame(_ frame: Data) throws {
        guard frame.count >= 12, frame[0] == 0, frame[1] <= 3 else { throw E2EError.framing }
        let type = frame[1], flags = UInt16(frame.uintBE(2, 2)), id = frame.uintBE(4, 4), length = frame.uintBE(8, 4)
        guard flags & ~UInt16(15) == 0,
              type == 0 ? (length <= 65_507 && frame.count == 12 + Int(length)) : frame.count == 12 else { throw E2EError.framing }
        if type == 2 {
            guard id == 0, flags == 1 || flags == 2 else { throw E2EError.framing }
            if flags == 1 { try sendFrame(type: 2, flags: 2, id: 0, length: length) }
            else if length == pingID { lastPing = nil }
            return
        }
        if type == 3 {
            guard id == 0, flags == 0 else { throw E2EError.framing }
            if length == 3 { terminalError = .removed }
            close(); return
        }
        guard id > 0, id % 2 == 1, id < nextID else { throw E2EError.framing }
        guard let pipe = streams[id] else { return }
        guard flags & 1 == 0 else { throw E2EError.framing }
        if flags & 8 != 0 {
            guard flags == 8, type == 1, length == 0 else { throw E2EError.framing }
            pipe.tcp.cancel(); streams.removeValue(forKey: id); return
        }
        if flags & 2 != 0 {
            guard type == 1, !pipe.acknowledged else { throw E2EError.framing }
            pipe.acknowledged = true
        }
        if type == 1 {
            guard pipe.sendWindow + Int(length) <= Int(UInt32.max) else { throw E2EError.framing }
            pipe.sendWindow += Int(length)
            readTCP(id)
        } else {
            guard pipe.acknowledged, !pipe.remoteFIN, Int(length) <= pipe.recvWindow, flags & 2 == 0 else { throw E2EError.framing }
            pipe.recvWindow -= Int(length)
            pipe.tcp.send(content: Data(frame.dropFirst(12)), completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self, let pipe = self.streams[id], !self.closed else { return }
                    if error != nil { try? self.reset(id); return }
                    pipe.consumed += Int(length)
                    if pipe.consumed >= 1_048_576 {
                        let grant = pipe.consumed
                        pipe.consumed = 0; pipe.recvWindow += grant
                        do { try self.sendFrame(type: 1, flags: 0, id: id, length: UInt32(grant)) } catch { self.close() }
                    }
                }
            })
        }
        if flags & 4 != 0 {
            guard !pipe.remoteFIN else { throw E2EError.framing }
            pipe.remoteFIN = true
            pipe.tcp.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            reap(id)
        }
    }

    private func reset(_ id: UInt32) throws {
        try sendFrame(type: 1, flags: 8, id: id, length: 0)
        streams.removeValue(forKey: id)?.tcp.cancel()
    }
    private func reap(_ id: UInt32) {
        guard let pipe = streams[id], pipe.localFIN, pipe.remoteFIN else { return }
        streams.removeValue(forKey: id)
        // NWConnection delivers its queued sends before the final message.
    }
    func close() {
        guard !closed else { return }
        closed = true
        reader?.cancel(); timer?.cancel(); sender?.cancel()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        socket?.cancel(with: .goingAway, reason: nil); session?.invalidateAndCancel()
        for pipe in streams.values { pipe.tcp.cancel() }
        streams.removeAll(); outbox.removeAll(); queuedBytes = 0
    }
}
