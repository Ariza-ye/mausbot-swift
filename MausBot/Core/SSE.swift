import Foundation

struct SSEFrame {
    var id: String?
    var json: JSON
}

extension ApiClient {
    /// One attempt at `/api/events`. Reconnection, backoff and route failover
    /// belong to the caller; a stream that ends before `hello` is treated as a
    /// route that never connected.
    func eventStream(lastEventId: String?) -> AsyncThrowingStream<SSEFrame, Error> {
        let base = baseURL
        let token = self.token
        return AsyncThrowingStream { continuation in
            let helloDeadline = Task {
                do {
                    try await Task.sleep(nanoseconds: 15_000_000_000)
                    continuation.finish(throwing: MissingStreamHello())
                } catch {}
            }
            let task = Task {
                defer { helloDeadline.cancel() }
                do {
                    guard let url = URL(string: base + "/api/events") else {
                        throw APIError(status: 0, message: "事件流地址无效", body: nil)
                    }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 90
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                    request.setValue("MausBot-macOS/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
                    if let lastEventId { request.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID") }
                    if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

                    let prepared = try await self.prepare(request)
                    let (bytes, response) = try await ApiClient.streamSession.bytes(for: prepared)
                    guard let http = response as? HTTPURLResponse else {
                        throw APIError(status: 0, message: "事件流没有响应", body: nil)
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 4096 { break }
                        }
                        let text = String(data: data, encoding: .utf8)
                        let message = jsonObject(data)?.nonEmpty("error") ?? text ?? "事件流被拒绝（HTTP \(http.statusCode)）"
                        throw APIError(status: http.statusCode, message: message, body: text)
                    }

                    // Split on newlines ourselves: the async line sequence drops
                    // blank lines, and a blank line is what ends an SSE frame.
                    var dataLines: [String] = []
                    var frameId: String?
                    var lineBuffer = Data()
                    func dispatchIfNeeded() {
                        guard !dataLines.isEmpty else { return }
                        let payload = dataLines.joined(separator: "\n")
                        if let json = jsonObject(payload) {
                            if json.str("kind") == "hello" { helloDeadline.cancel() }
                            continuation.yield(SSEFrame(id: frameId, json: json))
                        }
                        dataLines.removeAll(keepingCapacity: true)
                    }
                    func handle(_ line: String) {
                        if line.isEmpty {
                            dispatchIfNeeded()
                            frameId = nil
                        } else if line.hasPrefix(":") {
                            // keepalive comment
                        } else if line.hasPrefix("data:") {
                            var chunk = String(line.dropFirst(5))
                            if chunk.hasPrefix(" ") { chunk = String(chunk.dropFirst()) }
                            dataLines.append(chunk)
                        } else if line.hasPrefix("id:") {
                            frameId = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                        }
                    }
                    for try await byte in bytes {
                        if Task.isCancelled { break }
                        if byte == 0x0A {
                            var lineBytes = lineBuffer
                            if lineBytes.last == 0x0D { lineBytes.removeLast() }
                            lineBuffer.removeAll(keepingCapacity: true)
                            handle(String(decoding: lineBytes, as: UTF8.self))
                        } else {
                            lineBuffer.append(byte)
                            if lineBuffer.count > 2_000_000 { lineBuffer.removeAll(keepingCapacity: true) }
                        }
                    }
                    dispatchIfNeeded()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                helloDeadline.cancel()
                task.cancel()
            }
        }
    }
}

/// Raised when a stream answered but ended before its `hello` frame: a captive
/// page or proxy must not look like a healthy computer forever.
struct MissingStreamHello: Error, LocalizedError {
    var errorDescription: String? { "电脑接受了连接，但没有开始会话。" }
}
