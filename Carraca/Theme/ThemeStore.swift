import SwiftUI

/// Tema activo (se pide al panel al abrir y al volver a la app; como mucho cada 30 min).
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()
    /// Ajustes > Apariencia: decoración (lo que cae, brillo y saludo). El color y la fila especial siguen.
    nonisolated static let decorKey = "carraca.pref.decoracion"
    private static let cacheKey = "carraca.tema.cache"
    private static let url = URL(string: AppConfig.panel + "/tema.json")!

    @Published private(set) var current: SeasonTheme?
    @Published private(set) var effects = 2
    /// Reproductor abierto: la animación se para (ni se ve ni debe gastar batería).
    @Published var paused = false
    /// Momento en marcha (Nochevieja, un partido…) y el siguiente, si está en su cuenta atrás.
    @Published private(set) var moment: ThemeMoment?
    @Published private(set) var upcoming: ThemeMoment?

    private var config: ThemeConfig?
    private var lastFetch = Date.distantPast
    private var tick: Task<Void, Never>?

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.cacheKey) {
            config = try? JSONDecoder().decode(ThemeConfig.self, from: d)
        }
        recompute()
    }

    /// Clave del saludo: si se cierra, no vuelve a salir hasta que cambie el tema o el texto.
    var bannerKey: String { (current?.id ?? "") + "|" + (current?.message ?? "") }

    func refresh(force: Bool = false) async {
        recompute()     // puede haber cambiado el día
        guard force || Date().timeIntervalSince(lastFetch) > 1800 else { return }
        lastFetch = Date()
        let req = URLRequest(url: Self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        guard let res = try? await URLSession.shared.data(for: req),
              (res.1 as? HTTPURLResponse)?.statusCode == 200,
              let cfg = try? JSONDecoder().decode(ThemeConfig.self, from: res.0) else { return }
        UserDefaults.standard.set(res.0, forKey: Self.cacheKey)
        config = cfg
        recompute()
    }

    private func lookup(_ id: String) -> SeasonTheme? {
        guard var x = SeasonTheme.catalog[id] ?? config?.custom[id] else { return nil }
        if let o = config?.texts[id] {
            if let m = o.message { x.message = m }
            if let r = o.rail, !r.isEmpty { x.railTitle = r }
            if let k = o.keywords { x.keywords = k }
            if let a = o.ornaments { x.ornaments = a }
            if let p = o.particles { x.particles = p }
            if let s = o.screens { x.screens = Set(s) }
        }
        return x
    }

    private func recompute() {
        let now = Date()
        let moments = config?.moments ?? []
        let active = moments.first { $0.start <= now && now < $0.end }
        let next = moments.filter { $0.countdown > 0 && $0.start > now && $0.start.timeIntervalSince(now) <= $0.countdown }
            .min { $0.start < $1.start }
        var t = active?.theme.flatMap(lookup) ?? config?.activeID(on: now).flatMap(lookup)
        if let m = active, !m.message.isEmpty || m.effect != .off {
            var x = t ?? .neutral
            if !m.message.isEmpty { x.message = m.message }
            t = x
        }
        if t != current { current = t }
        if active != moment { moment = active }
        if next != upcoming { upcoming = next }
        let e = config?.effects ?? 2
        if e != effects { effects = e }
        applyWindowTint()
        scheduleTick(moments, now)
    }

    /// Despierta justo cuando empieza / acaba una cuenta atrás o un momento (las 00:00 en punto).
    private func scheduleTick(_ moments: [ThemeMoment], _ now: Date) {
        tick?.cancel()
        let edges = moments.flatMap { [$0.start.addingTimeInterval(-$0.countdown), $0.start, $0.end] }.filter { $0 > now }
        guard let first = edges.min() else { tick = nil; return }
        let wait = min(3600, max(0.2, first.timeIntervalSince(now) + 0.05))
        tick = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    /// Lo de UIKit (alertas, menús, barra de pestañas) también con el color del tema.
    func applyWindowTint() {
        let c = current?.accentUI ?? UIColor(named: "AccentColor")
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows { w.tintColor = c }
        }
    }
}
