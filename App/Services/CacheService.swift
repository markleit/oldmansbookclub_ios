import Foundation

final class CacheService {
    static let shared = CacheService()

    // Serial queue so writes never interleave and never run on the caller's thread.
    private let ioQueue = DispatchQueue(label: "CacheService.io", qos: .utility)

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private init() {}

    // Caches/ — iOS purges automatically under disk pressure, not backed up to iCloud,
    // matches the regenerable-from-server semantics of message data.
    private func fileURL(key: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cache_\(key).json")
    }

    // Encode + write happen OFF the calling thread (serialized). Callers fire-and-forget
    // from the @MainActor; doing this synchronously over a large message list was
    // stalling the UI every time a message arrived in an open chat.
    func save<T: Encodable & Sendable>(_ value: T, key: String) {
        let url = fileURL(key: key)
        ioQueue.async {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    // Synchronous variant: blocks until the encode+write finishes, serialized behind any
    // queued async saves. Used on a background push wake, where returning before the write
    // lands risks the app being suspended and the data lost.
    func saveSync<T: Encodable & Sendable>(_ value: T, key: String) {
        let url = fileURL(key: key)
        ioQueue.sync {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(value) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = try? Data(contentsOf: fileURL(key: key)) else { return nil }
        return try? decoder.decode(type, from: data)
    }
}
