import Foundation

/// The wire is JSON objects the desktop keeps growing. Every reader here is
/// tolerant: a missing or mistyped field falls back instead of failing a screen.
typealias JSON = [String: Any]

func jsonObject(_ data: Data) -> JSON? {
    (try? JSONSerialization.jsonObject(with: data)) as? JSON
}

func jsonObject(_ text: String) -> JSON? {
    guard let data = text.data(using: .utf8) else { return nil }
    return jsonObject(data)
}

func jsonData(_ object: Any) -> Data? {
    JSONSerialization.isValidJSONObject(object) ? try? JSONSerialization.data(withJSONObject: object) : nil
}

extension Dictionary where Key == String, Value == Any {
    func str(_ key: String) -> String? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        return value as? String
    }

    func nonEmpty(_ key: String) -> String? {
        guard let text = str(key), !text.isEmpty else { return nil }
        return text
    }

    func bool(_ key: String, _ fallback: Bool = false) -> Bool {
        guard let value = self[key], !(value is NSNull) else { return fallback }
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return fallback
            }
        }
        return fallback
    }

    func int(_ key: String) -> Int? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    func double(_ key: String) -> Double? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    func obj(_ key: String) -> JSON? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        return value as? JSON
    }

    func array(_ key: String) -> [Any]? {
        guard let value = self[key], !(value is NSNull) else { return nil }
        return value as? [Any]
    }

    func objArray(_ key: String) -> [JSON] {
        (array(key) ?? []).compactMap { $0 as? JSON }
    }

    func strArray(_ key: String) -> [String] {
        (array(key) ?? []).compactMap { value in
            if let text = value as? String { return text }
            return nil
        }
    }
}

/// `createdAt`/`updatedAt` on the wire are epoch milliseconds.
func wireDate(_ milliseconds: Int?) -> Date? {
    guard let milliseconds, milliseconds > 0 else { return nil }
    return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
}
