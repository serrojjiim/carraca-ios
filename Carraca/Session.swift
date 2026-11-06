import Foundation
import SwiftUI

/// Versión privada (Ad Hoc): compilada con CARRACA_PRIVATE.
///  - servidor opcional (vacío = servidor Carraca de config.json), Deportes, Seguir viendo en el panel,
///    aviso de actualizaciones por config.json.
/// Versión genérica (TestFlight / App Store): reproductor sin contenido; el usuario pone su
/// servidor Xtream o su lista M3U. Seguir viendo se guarda en el propio dispositivo.
enum Flavor {
    #if CARRACA_PRIVATE
    static let isPrivate = true
    #else
    static let isPrivate = false
    #endif
}

enum LoginError: LocalizedError {
    case empty, noServer, badM3U
    var errorDescription: String? {
        switch self {
        case .empty: return "Introduce usuario y contraseña."
        case .noServer: return "Introduce la dirección del servidor."
        case .badM3U: return "No se ha podido leer la lista M3U (comprueba la URL)."
        }
    }
}

/// Qué reproducir y, si es VOD, con qué datos guardarlo en "Seguir viendo".
struct PlayItem: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    var subtitle: String? = nil
    var isLive = false
    var liveStreamId: Int? = nil
    var startMs = 0
    var resume: ResumeTarget? = nil
    /// Directo: lista desde la que se abrió el canal, para cambiar a anterior/siguiente.
    var channels: [LiveStream] = []
    var channelIndex = 0
    var channelURL: ((LiveStream) -> URL)? = nil
    /// Directo: todos los canales de la cuenta (para saltar a un canal reciente de otra categoría).
    var allChannels: [LiveStream] = []
    /// Series: lo que va después (siguiente capítulo automático al acabar).
    var next: (() -> PlayItem?)? = nil
}

/// Preferencias de reproducción (Ajustes > Reproducción).
enum PlaybackPrefs {
    static let audioKey = "carraca.pref.audio"          // "" | castellano | latino | ingles
    static let subsKey = "carraca.pref.subs"            // "" | off | castellano | ingles | forzados
    static let autoNextKey = "carraca.pref.autonext"    // Bool (por defecto true)

    static var audio: String { UserDefaults.standard.string(forKey: audioKey) ?? "" }
    static var subs: String { UserDefaults.standard.string(forKey: subsKey) ?? "" }
    static var autoNext: Bool { UserDefaults.standard.object(forKey: autoNextKey) as? Bool ?? true }

    /// ¿El nombre de la pista encaja con la preferencia?
    static func matches(_ name: String, _ pref: String) -> Bool {
        let n = name.lowercased()
        switch pref {
        case "castellano":
            if ["latino", "latam", "lat)", "mexic"].contains(where: { n.contains($0) }) { return false }
            return ["castellano", "españa", "spain", "spa", "esp", "español", "spanish"].contains(where: { n.contains($0) })
        case "latino":
            return ["latino", "latam", "lat", "mexic"].contains(where: { n.contains($0) })
        case "ingles":
            return ["eng", "english", "inglés", "ingles"].contains(where: { n.contains($0) })
        case "forzados":
            return ["forz", "forced"].contains(where: { n.contains($0) })
        default:
            return false
        }
    }
}

struct ResumeTarget {
    let type: String      // "movie" | "series"
    let name: String      // nombre tal cual lo da el proveedor
    let itemId: String
    var season = 0
    var episode = 0
}

/// Datos que llegan por el enlace carraca://login?s=…&u=…&p=…  (o &m3u=…)
struct LoginPrefill: Equatable {
    var server = ""
    var user = ""
    var pass = ""
    var m3u = ""
}

@MainActor
final class Session: ObservableObject {
    @Published private(set) var api: XtreamAPI?
    @Published private(set) var creds: Credentials?
    @Published var account: AuthResponse?
    @Published var remote: RemoteConfig?
    @Published var update: RemoteConfig?
    @Published var resume: [ResumeItem] = []
    @Published var prefill: LoginPrefill?
    /// Sube al pulsar "Recargar listas": las pestañas lo vigilan y vuelven a descargar al momento.
    @Published var reloadToken = 0

    var isLoggedIn: Bool { creds != nil }
    var isM3U: Bool { creds?.m3u != nil }

    /// Pestaña "Eventos" (agenda pública de deportes del día): visible para todos los usuarios,
    /// sin depender de qué servidor usen (nada oculto para la revisión de Apple).
    var showsEvents: Bool { true }

    /// Cuenta Xtream del servidor Carraca (el mismo de la app Android).
    var isCarracaServer: Bool {
        guard let c = creds, c.m3u == nil else { return false }
        if c.usesDefaultServer { return true }
        return CarracaServers.isCarraca(c.server)
    }

    /// Seguir viendo: con cuentas del servidor Carraca lo guarda el panel (resume.php), así lo
    /// empezado en la tele sigue en el móvil y al revés; con otros servidores, el propio dispositivo.
    var resumeEnabled: Bool {
        guard let c = creds, c.m3u == nil else { return false }
        return Flavor.isPrivate ? c.usesDefaultServer : true
    }
    var remoteResume: Bool { resumeEnabled && isCarracaServer }

    init() {
        if let c = Keychain.load() { apply(c) }
        Task {
            await refreshRemote()
            await refreshResume()
            if let api { account = try? await api.authenticate() }
        }
    }

    private func apply(_ c: Credentials) {
        creds = c
        api = c.m3u == nil ? XtreamAPI(base: c.server, user: c.user, pass: c.pass) : nil
        favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        watchlist = UserDefaults.standard.stringArray(forKey: watchlistKey) ?? []
        GuideStore.shared.reset()
    }

    // MARK: Guía "ahora / después" (solo cuentas del servidor Carraca: la genera su panel)

    var guideEnabled: Bool { isCarracaServer }

    /// La guía vive aparte (GuideStore): cuando se actualiza solo se repintan los canales,
    /// no las pestañas de pelis y series.
    func refreshGuide(force: Bool = false) async {
        await GuideStore.shared.refresh(enabled: guideEnabled, force: force)
    }

    // MARK: Último canal visto

    private var lastChannelKey: String { "carraca.lastch." + favoritesKey }
    var lastChannelID: Int? {
        get { UserDefaults.standard.object(forKey: lastChannelKey) as? Int }
        set { UserDefaults.standard.set(newValue, forKey: lastChannelKey); objectWillChange.send() }
    }

    /// Mientras se ve la tele se guarda sin avisar a las pantallas (nada se repinta detrás del
    /// reproductor en cada cambio de canal); al cerrar el reproductor se avisa una sola vez.
    func storeLastChannel(_ id: Int) {
        UserDefaults.standard.set(id, forKey: lastChannelKey)
        var r = recentChannelIDs.filter { $0 != id }
        r.insert(id, at: 0)
        UserDefaults.standard.set(Array(r.prefix(Self.recentMax)), forKey: recentKey)
    }

    // MARK: Canales recientes (los últimos vistos, el primero es el último)

    static let recentMax = 8
    private var recentKey: String { "carraca.recentch." + favoritesKey }
    var recentChannelIDs: [Int] { UserDefaults.standard.array(forKey: recentKey) as? [Int] ?? lastChannelID.map { [$0] } ?? [] }

    // MARK: Mi lista (pelis y series para ver luego, en el dispositivo)

    @Published private(set) var watchlist: [String] = []
    private var watchlistKey: String { "carraca.milista." + favoritesKey }

    nonisolated static func listKey(movie id: Int) -> String { "m\(id)" }
    nonisolated static func listKey(series id: Int) -> String { "s\(id)" }

    func inList(_ key: String) -> Bool { watchlist.contains(key) }

    func toggleList(_ key: String) {
        if let i = watchlist.firstIndex(of: key) { watchlist.remove(at: i) } else { watchlist.insert(key, at: 0) }
        UserDefaults.standard.set(watchlist, forKey: watchlistKey)
    }

    // MARK: Favoritos (por cuenta, guardados en el dispositivo)

    @Published private(set) var favorites: Set<String> = []

    private var favoritesKey: String {
        guard let c = creds else { return "carraca.fav" }
        return "carraca.fav." + (c.m3u ?? (c.user + "@" + c.server))
    }

    static func favoriteID(_ s: LiveStream) -> String { s.directURL?.absoluteString ?? "x\(s.id)" }

    func isFavorite(_ s: LiveStream) -> Bool { favorites.contains(Session.favoriteID(s)) }

    func toggleFavorite(_ s: LiveStream) {
        let id = Session.favoriteID(s)
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
    }

    // MARK: Visto (pelis y capítulos terminados)

    /// Claves "movie|nombre" y "series|serie|temporada|capítulo" (mismo formato que resume.php).
    @Published private(set) var watched: Set<String> = []

    static func watchKey(movie name: String) -> String {
        "movie|" + name.trimmingCharacters(in: .whitespaces).lowercased()
    }

    static func watchKey(series name: String, season: Int, episode: Int) -> String {
        let full = name.trimmingCharacters(in: .whitespaces).lowercased()
        let base = full.seriesBaseNameAnyCase.trimmingCharacters(in: .whitespaces)
        return "series|\(base.isEmpty ? full : base)|\(season)|\(episode)"
    }

    func isWatched(movie name: String) -> Bool { watched.contains(Session.watchKey(movie: name)) }

    func isWatched(series name: String, season: Int, episode: Int) -> Bool {
        watched.contains(Session.watchKey(series: name, season: season, episode: episode))
    }

    func isWatched(download it: DownloadItem) -> Bool {
        it.kind == "series" ? isWatched(series: it.resumeName, season: it.season, episode: it.episode)
                            : isWatched(movie: it.resumeName)
    }

    /// Marcar / desmarcar a mano.
    func setWatched(type: String, name: String, season: Int = 0, episode: Int = 0, on: Bool) {
        let key = type == "series" ? Session.watchKey(series: name, season: season, episode: episode) : Session.watchKey(movie: name)
        if on { watched.insert(key) } else { watched.remove(key) }
        if on { Downloads.shared.removeWatched(self.isWatched(download:)) }
        guard let user = creds?.user else { return }
        if remoteResume {
            let body: [String: Any] = ["user": user, "action": "visto", "on": on, "type": type, "name": name,
                                       "season": season, "episode": episode]
            var req = URLRequest(url: AppConfig.resumeURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: req).resume()
        } else {
            saveLocalWatched()
        }
    }

    private var watchedDefaultsKey: String { "carraca.visto." + favoritesKey }

    private func saveLocalWatched() {
        UserDefaults.standard.set(Array(watched), forKey: watchedDefaultsKey)
    }

    private func refreshWatched() async {
        guard resumeEnabled, let user = creds?.user else { watched = []; return }
        if !remoteResume {
            watched = Set(UserDefaults.standard.stringArray(forKey: watchedDefaultsKey) ?? [])
            return
        }
        var comps = URLComponents(url: AppConfig.resumeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "user", value: user), URLQueryItem(name: "visto", value: "1")]
        guard let url = comps.url,
              let res = try? await URLSession.shared.data(from: url),
              let keys = try? JSONDecoder().decode([String].self, from: res.0) else { return }
        watched = Set(keys)
    }

    /// Último servidor usado (para rellenar el login si se cierra sesión).
    static let lastServerKey = "carraca.lastServer"

    // MARK: Enlace de acceso

    func handle(url: URL) {
        guard url.scheme == "carraca", url.host == "login",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        func v(_ k: String) -> String { items.first { $0.name == k }?.value ?? "" }
        prefill = LoginPrefill(server: v("s"), user: v("u"), pass: v("p"), m3u: v("m3u"))
    }

    // MARK: config.json

    /// Servidores Carraca (en las dos versiones: así se reconoce una cuenta de Carraca aunque la
    /// dirección se haya escrito a mano) y, solo en la privada, aviso de versión nueva.
    func refreshRemote() async {
        guard let res = try? await URLSession.shared.data(from: AppConfig.configURL),
              let cfg = try? JSONDecoder().decode(RemoteConfig.self, from: res.0) else { return }
        // ¿Era una cuenta de Carraca con los servidores de antes? (p. ej. la IP vieja tras migrar)
        let wasCarraca = creds.map { $0.m3u == nil && ($0.usesDefaultServer || CarracaServers.isCarraca($0.server)) } ?? false
        CarracaServers.remember(cfg)
        remote = cfg
        if Flavor.isPrivate, let v = cfg.iosVersionCode, v > AppConfig.build, cfg.iosInstallURL != nil {
            update = cfg
        }
        // Cuenta del servidor Carraca: si el servidor cambia (migración de VPS) se actualiza sola.
        if var c = creds, wasCarraca, let s = cfg.servers.first, s != c.server {
            c.server = s
            Keychain.save(c)
            apply(c)
        }
    }

    // MARK: Login

    func login(server: String, user: String, pass: String) async throws {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let custom = ServerURL.normalize(server)
        if custom.isEmpty && !Flavor.isPrivate { throw LoginError.noServer }
        guard !u.isEmpty, !pass.isEmpty else { throw LoginError.empty }

        var candidates: [String]
        if custom.isEmpty {
            if remote == nil { await refreshRemote() }
            candidates = remote?.servers ?? []
            // config.json no responde: el último servidor que dio
            if candidates.isEmpty, let last = CarracaServers.lastBase { candidates = [last] }
        } else {
            candidates = [custom]
        }

        var lastError: Error = APIError.badResponse
        for base in candidates {
            let api = XtreamAPI(base: base, user: u, pass: pass)
            do {
                let info = try await api.authenticate()
                let c = Credentials(server: base, user: u, pass: pass, usesDefaultServer: custom.isEmpty)
                if !custom.isEmpty { UserDefaults.standard.set(custom, forKey: Session.lastServerKey) }
                Keychain.save(c)
                apply(c)
                account = info
                await refreshResume()
                return
            } catch APIError.auth {
                throw APIError.auth
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func loginM3U(_ raw: String) async throws {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { throw LoginError.badM3U }
        let channels = try await fetchM3U(url, force: true)
        guard !channels.isEmpty else { throw LoginError.badM3U }
        let c = Credentials(server: "", user: "", pass: "", usesDefaultServer: false, m3u: s)
        Keychain.save(c)
        apply(c)
    }

    /// Canales de la lista M3U (caché 12 h).
    func m3uChannels(force: Bool = false) async throws -> [LiveStream] {
        guard let s = creds?.m3u, let url = URL(string: s) else { return [] }
        return try await fetchM3U(url, force: force)
    }

    private var m3uRefreshing = false

    private func fetchM3U(_ url: URL, force: Bool) async throws -> [LiveStream] {
        // Hash estable (djb2): hashValue cambia en cada arranque.
        let h = url.absoluteString.utf8.reduce(UInt64(5381)) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
        let key = "m3u_" + String(h, radix: 16)
        // La lista guardada se enseña al momento; si ha caducado, se actualiza por detrás.
        if !force, let hit = DiskCache.readDated(key, maxAge: .infinity) {
            let data = hit.0
            let list = await Task.detached(priority: .userInitiated) { M3U.parse(data: data) }.value
            if !list.isEmpty {
                if Date().timeIntervalSince(hit.1) >= XtreamAPI.listAge && !m3uRefreshing {
                    m3uRefreshing = true
                    Task {
                        let ok = (try? await downloadM3U(url, key: key)) != nil
                        m3uRefreshing = false
                        if ok { NotificationCenter.default.post(name: XtreamAPI.listRefreshed, object: "m3u") }
                    }
                }
                return list
            }
        }
        return try await downloadM3U(url, key: key)
    }

    private func downloadM3U(_ url: URL, key: String) async throws -> [LiveStream] {
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code) }
        let list = await Task.detached(priority: .userInitiated) { M3U.parse(data: data) }.value
        guard !list.isEmpty else { throw LoginError.badM3U }
        DiskCache.write(key, data)
        return list
    }

    func logout() {
        Keychain.delete()
        DiskCache.clear()
        LocalResume.clear()
        creds = nil
        api = nil
        account = nil
        resume = []
        watched = []
        watchlist = []
        GuideStore.shared.reset()
    }

    // MARK: Seguir viendo

    /// Quitar algo de "Seguir viendo" (deslizar a la izquierda) sin marcarlo como visto.
    func removeResume(_ item: ResumeItem) {
        resume.removeAll { $0.type == item.type && $0.name == item.name }
        guard let user = creds?.user else { return }
        if remoteResume {
            let body: [String: Any] = ["user": user, "action": "borrar", "type": item.type, "name": item.name]
            var req = URLRequest(url: AppConfig.resumeURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            URLSession.shared.dataTask(with: req).resume()
        } else {
            LocalResume.remove(type: item.type, name: item.name)
        }
    }

    /// URL guardada en "Seguir viendo" con el usuario y la contraseña de esta cuenta
    /// (el panel ya no devuelve las credenciales en la respuesta pública).
    func playableURL(_ raw: String) -> URL? {
        guard let c = creds, c.m3u == nil, !raw.isEmpty else { return URL(string: raw) }
        let enc: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? $0
        }
        let fixed = raw.replacingOccurrences(of: #"/(movie|series)/[^/]+/[^/]+/"#,
                                             with: "/$1/" + NSRegularExpression.escapedTemplate(for: enc(c.user)) + "/"
                                                 + NSRegularExpression.escapedTemplate(for: enc(c.pass)) + "/",
                                             options: .regularExpression)
        return URL(string: fixed)
    }

    func refreshResume() async {
        await refreshWatched()
        guard resumeEnabled, let user = creds?.user else { resume = []; return }
        if !remoteResume {
            resume = LocalResume.load()
            return
        }
        var comps = URLComponents(url: AppConfig.resumeURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "user", value: user)]
        guard let url = comps.url,
              let res = try? await URLSession.shared.data(from: url),
              let list = try? JSONDecoder().decode(LossyArray<ResumeItem>.self, from: res.0) else { return }
        resume = list.items.sorted { $0.ts > $1.ts }
    }

    func resumeFor(movie name: String) -> ResumeItem? {
        resume.first { $0.type == "movie" && $0.name == name }
    }

    func resumeFor(series name: String) -> ResumeItem? {
        resume.first { $0.type == "series" && ($0.name == name || $0.name.seriesBaseName == name) }
    }

    /// Guarda el progreso (panel en la privada, dispositivo en la genérica).
    /// No toca `resume`: eso repintaría todas las pestañas detrás del reproductor cada 30 s.
    /// La lista se vuelve a leer al cerrar el reproductor.
    func report(_ item: PlayItem, timeMs: Int, lengthMs: Int) {
        guard resumeEnabled, let r = item.resume, let user = creds?.user,
              lengthMs > 60_000, timeMs > 10_000 else { return }
        let pro = min(100, max(0, Int(Double(timeMs) / Double(lengthMs) * 100)))
        if pro >= 95 {
            let key = r.type == "series" ? Session.watchKey(series: r.name, season: r.season, episode: r.episode)
                                         : Session.watchKey(movie: r.name)
            if !watched.contains(key) {
                watched.insert(key)
                if !remoteResume { saveLocalWatched() }   // en el panel lo apunta resume.php
            }
        }

        if !remoteResume {
            LocalResume.upsert(ResumeItem(type: r.type, name: r.name, itemId: r.itemId, url: item.url.absoluteString,
                                          season: r.season, episode: r.episode, position: timeMs,
                                          duration: lengthMs, pro: pro, ts: Int(Date().timeIntervalSince1970)))
            return
        }

        let body: [String: Any] = [
            "user": user, "type": r.type, "name": r.name, "id": r.itemId,
            "url": item.url.absoluteString, "season": r.season, "episode": r.episode,
            "position": timeMs, "duration": lengthMs, "pro": pro,
        ]
        var req = URLRequest(url: AppConfig.resumeURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }
}

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
