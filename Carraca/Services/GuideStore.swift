import SwiftUI

// MARK: - Guía "ahora / después"

/// Guía de todos los canales (epg_now.php del panel). Va aparte de Session para que su
/// actualización (cada 10 min) solo repinte las filas de canales; se descarga y se procesa
/// fuera del hilo principal (son ~400 KB).
@MainActor
final class GuideStore: ObservableObject {
    static let shared = GuideStore()

    @Published private(set) var guide: [String: [GuideEntry]] = [:]
    private var loaded = Date.distantPast

    func reset() {
        guide = [:]
        loaded = .distantPast
    }

    /// Una petición para todos los canales; como mucho cada 10 minutos.
    func refresh(enabled: Bool, force: Bool = false) async {
        guard enabled, force || Date().timeIntervalSince(loaded) > 600 else { return }
        loaded = Date()
        guard let url = URL(string: AppConfig.panel + "/epg_now.php") else { return }
        let parsed: [String: [GuideEntry]]? = await Task.detached(priority: .utility) {
            guard let res = try? await URLSession.shared.data(from: url) else { return nil }
            return GuideStore.parse(res.0)
        }.value
        if let parsed { guide = parsed }
    }

    nonisolated static func parse(_ data: Data) -> [String: [GuideEntry]]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let chans = obj["c"] as? [String: [[Any]]] else { return nil }
        var g: [String: [GuideEntry]] = [:]
        g.reserveCapacity(chans.count)
        for (id, list) in chans {
            g[id] = list.compactMap { p in
                guard p.count >= 3, let a = (p[0] as? NSNumber)?.doubleValue, let b = (p[1] as? NSNumber)?.doubleValue,
                      let t = p[2] as? String else { return nil }
                return GuideEntry(start: Date(timeIntervalSince1970: a), end: Date(timeIntervalSince1970: b), title: t)
            }
        }
        return g
    }

    /// Lo que echan ahora (y después) en un canal.
    func nowNext(_ s: LiveStream) -> [GuideEntry] {
        guard let id = s.epgId, let list = guide[id] else { return [] }
        let now = Date()
        return Array(list.lazy.filter { $0.end > now }.prefix(2))
    }
}
