import Foundation
import SwiftUI

enum LoginError: LocalizedError {
    case empty
    var errorDescription: String? { "Introduce usuario y contraseña." }
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
}

struct ResumeTarget {
    let type: String      // "movie" | "series"
    let name: String      // nombre tal cual lo da el proveedor (clave en resume.php)
    let itemId: String
    var season = 0
    var episode = 0
}

@MainActor
final class Session: ObservableObject {
    @Published private(set) var api: XtreamAPI?
    @Published private(set) var creds: Credentials?
    @Published var account: AuthResponse?
    @Published var remote: RemoteConfig?
    @Published var update: RemoteConfig?
    @Published var resume: [ResumeItem] = []

    /// "Seguir viendo" solo para cuentas del servidor Carraca (el panel guarda por usuario).
    var resumeEnabled: Bool { creds?.usesDefaultServer == true }

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
        api = XtreamAPI(base: c.server, user: c.user, pass: c.pass)
    }

    func refreshRemote() async {
        guard let res = try? await URLSession.shared.data(from: AppConfig.configURL),
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

    /// Servidor vacío = servidor Carraca (leído de config.json).
    func login(server: String, user: String, pass: String) async throws {
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, !pass.isEmpty else { throw LoginError.empty }

        let custom = ServerURL.normalize(server)
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

    func logout() {
        Keychain.delete()
        DiskCache.clear()
        creds = nil
        api = nil
        account = nil
        resume = []
    }

    // MARK: Seguir viendo

    func refreshResume() async {
        guard resumeEnabled, let user = creds?.user else { resume = []; return }
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

    /// Guarda el progreso en el panel (mismo formato que la app Android).
    func report(_ item: PlayItem, timeMs: Int, lengthMs: Int) {
        guard resumeEnabled, let r = item.resume, let user = creds?.user,
              lengthMs > 60_000, timeMs > 10_000 else { return }
        let pro = min(100, max(0, Int(Double(timeMs) / Double(lengthMs) * 100)))
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
