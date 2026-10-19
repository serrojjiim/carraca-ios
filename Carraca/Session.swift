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

    var isLoggedIn: Bool { creds != nil }
    var isM3U: Bool { creds?.m3u != nil }

    /// Servidores Carraca conocidos (proxy IPTV + dominio del panel).
    static let carracaHosts: Set<String> = ["82.165.142.230", "carracaservice.duckdns.org"]

    /// Pestaña "Eventos" (Deportes de hoy del panel): siempre en la privada; en la genérica,
    /// solo si la cuenta es del servidor Carraca (el resto de usuarios no la ve).
    var showsEvents: Bool {
        if Flavor.isPrivate { return true }
        guard let s = creds?.server, let host = URL(string: s)?.host else { return false }
        return Session.carracaHosts.contains(host)
    }

    /// Seguir viendo: en la privada lo guarda el panel (si la cuenta es del servidor Carraca);
    /// en la genérica, el propio dispositivo (solo cuentas Xtream, que tienen pelis y series).
    var resumeEnabled: Bool {
        guard let c = creds, c.m3u == nil else { return false }
        return Flavor.isPrivate ? c.usesDefaultServer : true
    }
    private var remoteResume: Bool { Flavor.isPrivate && creds?.usesDefaultServer == true }

    init() {
        if let c = Keychain.load() { apply(c) }
        Task {
            if Flavor.isPrivate { await refreshRemote() }
            await refreshResume()
            if let api { account = try? await api.authenticate() }
        }
    }

    private func apply(_ c: Credentials) {
        creds = c
        api = c.m3u == nil ? XtreamAPI(base: c.server, user: c.user, pass: c.pass) : nil
    }

    // MARK: Enlace de acceso

    func handle(url: URL) {
        guard url.scheme == "carraca", url.host == "login",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        func v(_ k: String) -> String { items.first { $0.name == k }?.value ?? "" }
        prefill = LoginPrefill(server: v("s"), user: v("u"), pass: v("p"), m3u: v("m3u"))
    }

    // MARK: config.json (solo versión privada)

    func refreshRemote() async {
        guard Flavor.isPrivate,
              let res = try? await URLSession.shared.data(from: AppConfig.configURL),
              let cfg = try? JSONDecoder().decode(RemoteConfig.self, from: res.0) else { return }
        remote = cfg
        if let v = cfg.iosVersionCode, v > AppConfig.build, cfg.iosInstallURL != nil {
            update = cfg
        }
        // Cuenta en el servidor Carraca: si cambia (migración de VPS) se actualiza sola.
        if var c = creds, c.usesDefaultServer, let s = cfg.servers.first, s != c.server {
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
            if candidates.isEmpty { candidates = [AppConfig.fallbackServer] }
        } else {
            candidates = [custom]
        }

        var lastError: Error = APIError.badResponse
        for base in candidates {
            let api = XtreamAPI(base: base, user: u, pass: pass)
            do {
                let info = try await api.authenticate()
                let c = Credentials(server: base, user: u, pass: pass, usesDefaultServer: custom.isEmpty)
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

    private func fetchM3U(_ url: URL, force: Bool) async throws -> [LiveStream] {
        // Hash estable (djb2): hashValue cambia en cada arranque.
        let h = url.absoluteString.utf8.reduce(UInt64(5381)) { ($0 &<< 5) &+ $0 &+ UInt64($1) }
        let key = "m3u_" + String(h, radix: 16)
        if !force, let d = DiskCache.read(key, maxAge: XtreamAPI.listAge), let t = String(data: d, encoding: .utf8) {
            return M3U.parse(t)
        }
        let (data, resp) = try await URLSession.shared.data(from: url)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw APIError.http(code)
        }
        DiskCache.write(key, data)
        return M3U.parse(text)
    }

    func logout() {
        Keychain.delete()
        DiskCache.clear()
        LocalResume.clear()
        creds = nil
        api = nil
        account = nil
        resume = []
    }

    // MARK: Seguir viendo

    func refreshResume() async {
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
    func report(_ item: PlayItem, timeMs: Int, lengthMs: Int) {
        guard resumeEnabled, let r = item.resume, let user = creds?.user,
              lengthMs > 60_000, timeMs > 10_000 else { return }
        let pro = min(100, max(0, Int(Double(timeMs) / Double(lengthMs) * 100)))

        if !remoteResume {
            LocalResume.upsert(ResumeItem(type: r.type, name: r.name, itemId: r.itemId, url: item.url.absoluteString,
                                          season: r.season, episode: r.episode, position: timeMs,
                                          duration: lengthMs, pro: pro, ts: Int(Date().timeIntervalSince1970)))
            resume = LocalResume.load()
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
