import UIKit

// MARK: - Caché en disco

enum DiskCache {
    static let dir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("xtream", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private static func file(_ key: String) -> URL {
        let safe = key.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return dir.appendingPathComponent(safe + ".json")
    }

    static func read(_ key: String, maxAge: TimeInterval) -> Data? {
        readDated(key, maxAge: maxAge)?.0
    }

    /// Los datos y cuándo se guardaron.
    static func readDated(_ key: String, maxAge: TimeInterval) -> (Data, Date)? {
        let f = file(key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
              let mod = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mod) < maxAge,
              let data = try? Data(contentsOf: f) else { return nil }
        return (data, mod)
    }

    static func write(_ key: String, _ data: Data) {
        try? data.write(to: file(key), options: .atomic)
    }

    static func clear() {
        MemCache.shared.clear()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

/// Caché en memoria de lo ya decodificado (caduca a la vez que la copia en disco).
/// Si iOS avisa de poca memoria, se vacía y se vuelve a leer del disco cuando haga falta.
final class MemCache: @unchecked Sendable {
    static let shared = MemCache()
    private let lock = NSLock()
    private var items: [String: (value: Any, at: Date)] = [:]

    private init() {
        NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.clear() }
    }

    /// Lo guardado y cuándo (aunque esté caducado).
    func entry<T>(_ key: String) -> (value: T, at: Date)? {
        lock.lock(); defer { lock.unlock() }
        guard let e = items[key], let v = e.value as? T else { return nil }
        return (v, e.at)
    }

    func set(_ key: String, _ value: Any, at: Date) {
        lock.lock(); defer { lock.unlock() }
        items[key] = (value, at)
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        items.removeAll()
    }
}
