import SwiftUI
import CryptoKit

/// Caché propia de carátulas y logos: memoria + disco, reducidas al tamaño en que se ven
/// (menos memoria y scroll más fluido) y sin pedir dos veces la misma imagen a la vez.
actor ImageLoader {
    static let shared = ImageLoader()

    nonisolated let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 600
        return c
    }()
    private var tasks: [String: Task<UIImage?, Never>] = [:]

    static let dir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("img", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    private static func key(_ url: URL, _ maxPixel: Int) -> String {
        let h = SHA256.hash(data: Data((url.absoluteString + "#\(maxPixel)").utf8))
        return h.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated func cached(_ url: URL, maxPixel: Int) -> UIImage? {
        memory.object(forKey: Self.key(url, maxPixel) as NSString)
    }

    func image(_ url: URL, maxPixel: Int) async -> UIImage? {
        let k = Self.key(url, maxPixel)
        if let m = memory.object(forKey: k as NSString) { return m }
        if let t = tasks[k] { return await t.value }
        let t = Task<UIImage?, Never>.detached(priority: .utility) { await Self.load(url, key: k, maxPixel: maxPixel) }
        tasks[k] = t
        let img = await t.value
        tasks[k] = nil
        if let img { memory.setObject(img, forKey: k as NSString) }
        return img
    }

    private static func load(_ url: URL, key: String, maxPixel: Int) async -> UIImage? {
        let file = dir.appendingPathComponent(key + ".jpg")
        if let d = try? Data(contentsOf: file), let img = UIImage(data: d) {
            return await img.byPreparingForDisplay() ?? img
        }
        guard let res = try? await URLSession.shared.data(from: url),
              (res.1 as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let img = UIImage(data: res.0) else { return nil }
        // reducir al tamaño en que se pinta (un póster no necesita 2000 px)
        let scale = min(1, CGFloat(maxPixel) / max(img.size.width * img.scale, img.size.height * img.scale))
        let target = CGSize(width: img.size.width * img.scale * scale, height: img.size.height * img.scale * scale)
        let small = (scale < 1 ? await img.byPreparingThumbnail(ofSize: target) : await img.byPreparingForDisplay()) ?? img
        if let jpg = small.jpegData(compressionQuality: 0.85) { try? jpg.write(to: file, options: .atomic) }
        return small
    }

    /// Precarga (filas de carátulas): que estén listas antes de llegar a ellas.
    nonisolated func prefetch(_ urls: [String?], maxPixel: Int = 480) {
        let list = urls.compactMap { $0.flatMap(URL.init(string:)) }
        Task.detached(priority: .background) {
            for u in list { _ = await self.image(u, maxPixel: maxPixel) }
        }
    }

    /// Limpieza al arrancar: lo que lleve más de 30 días sin tocarse.
    nonisolated static func trim() {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let limit = Date().addingTimeInterval(-30 * 86_400)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for f in files {
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if d < limit { try? fm.removeItem(at: f) }
            }
        }
    }
}
