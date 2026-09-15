import Foundation

/// Minimal persistence seam. On iOS this is backed by the shared App Group
/// container so the share extension and the host app enforce the *same* caps
/// and rate limits — an attacker who could get the extension to use a private
/// store would otherwise reset every counter simply by tipping from a different
/// entry point.
public protocol KeyValueStore: AnyObject, Sendable {
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

public final class InMemoryKeyValueStore: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data] = [:]

    public init() {}

    public func data(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func set(_ data: Data?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = data
    }
}

extension KeyValueStore {
    func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func encode<T: Encodable>(_ value: T, forKey key: String) {
        set(try? JSONEncoder().encode(value), forKey: key)
    }
}
