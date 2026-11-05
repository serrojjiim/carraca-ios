import SwiftUI
import CryptoKit

/// Caché propia de carátulas y logos: memoria + disco, reducidas al tamaño en que se ven
/// (menos memoria y scroll más fluido) y sin pedir dos veces la misma imagen a la vez.
actor ImageLoader {
    static let shared = ImageLoader()

    /// En memoria: limitado por bytes (un fondo de 1400 px pesa como 10 pósteres), ~1/8 de la RAM y 150 MB como mucho.
    nonisolated let memory: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 400
        c.totalCostLimit = Int(min(Double(ProcessInfo.processInfo.physicalMemory) / 8, 150 * 1_048_576))
        return c
    }()

    /// Sin URLCache: las imágenes ya se guardan reducidas en disco (antes iban dos veces).
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: cfg)
    }()

    private static func cost(_ img: UIImage) -> Int {
        guard let cg = img.cgImage else { return Int(img.size.width * img.size.height * img.scale * img.scale * 4) }
        return cg.bytesPerRow * cg.height
    }
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
        if let img { memory.setObject(img, forKey: k as NSString, cost: Self.cost(img)) }
        return img
    }

    private static func load(_ url: URL, key: String, maxPixel: Int) async -> UIImage? {
        // ".img": PNG si tiene transparencia (logos de canales), JPG si no. Antes todo iba en JPG
        // y los logos transparentes salían con un recuadro negro (y los oscuros, invisibles).
        let file = dir.appendingPathComponent(key + ".img")
        if let d = try? Data(contentsOf: file), let img = UIImage(data: d) {
            // en uso: que la limpieza de 30 días no se lo lleve
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return await img.byPreparingForDisplay() ?? img
        }
        guard let res = try? await session.data(from: url),
              (res.1 as? HTTPURLResponse)?.statusCode ?? 200 < 400,
              let img = UIImage(data: res.0) else { return nil }
        // reducir al tamaño en que se pinta (un póster no necesita 2000 px)
        let scale = min(1, CGFloat(maxPixel) / max(img.size.width * img.scale, img.size.height * img.scale))
        let target = CGSize(width: img.size.width * img.scale * scale, height: img.size.height * img.scale * scale)
        let small = (scale < 1 ? await img.byPreparingThumbnail(ofSize: target) : await img.byPreparingForDisplay()) ?? img
        let opaque: [CGImageAlphaInfo] = [CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast]
        let alpha = small.cgImage.map { !opaque.contains($0.alphaInfo) } ?? false
        if let data = alpha ? small.pngData() : small.jpegData(compressionQuality: 0.85) {
            try? data.write(to: file, options: .atomic)
        }
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
                // las copias viejas en JPG (sin transparencia) ya no se usan
                if f.pathExtension == "jpg" { try? fm.removeItem(at: f); continue }
                let d = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if d < limit { try? fm.removeItem(at: f) }
            }
        }
    }
}
