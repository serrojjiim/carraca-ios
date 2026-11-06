import Foundation

// MARK: - API Xtream

enum APIError: LocalizedError {
    case http(Int), auth, badResponse

    var errorDescription: String? {
        switch self {
        case .http(let code):
            return code == 403 ? "El servidor ha rechazado la conexión (403)." : "Error del servidor (\(code))."
        case .auth: return "Usuario o contraseña incorrectos."
        case .badResponse: return "Respuesta no válida del servidor."
        }
    }
}

final class XtreamAPI: @unchecked Sendable {
    let base: String
    let user: String
    let pass: String
    private let session: URLSession

    /// Las listas se guardan 12 h (como la app Android) para no cargar al proveedor.
    static let listAge: TimeInterval = 12 * 3600

    init(base: String, user: String, pass: String) {
        self.base = base
        self.user = user
        self.pass = pass
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 45
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = ["User-Agent": "CarracaiOS/\(AppConfig.version)"]
        session = URLSession(configuration: cfg)
    }

    private var cachePrefix: String { user + "_" + (URL(string: base)?.host ?? "srv") }

    private func endpoint(_ action: String?, _ extra: [String: String]) -> URL {
        var comps = URLComponents(string: base + "/player_api.php")!
        var q = [URLQueryItem(name: "username", value: user), URLQueryItem(name: "password", value: pass)]
        if let action { q.append(URLQueryItem(name: "action", value: action)) }
        for (k, v) in extra { q.append(URLQueryItem(name: k, value: v)) }
        comps.queryItems = q
        return comps.url!
    }

    /// Aviso de que una lista se ha actualizado por detrás (object = nombre de la lista: "vod", "live_cat"…).
    static let listRefreshed = Notification.Name("carraca.listRefreshed")

    /// Listas que se están actualizando por detrás (una sola petición a la vez por lista) y último intento.
    private static let lock = NSLock()
    private static var refreshing: Set<String> = []
    private static var lastTry: [String: Date] = [:]

    /// - stale: si la copia guardada ha caducado, se devuelve igualmente al momento y se actualiza
    ///   por detrás (al acabar se avisa con `listRefreshed`). Así no hay pantalla de carga cada 12 h.
    func get<T: Decodable>(_ type: T.Type, _ action: String?, _ extra: [String: String] = [:],
                           cache: String? = nil, maxAge: TimeInterval = 0, force: Bool = false,
                           stale: Bool = false) async throws -> T {
        let key = cache.map { cachePrefix + "_" + $0 }
        if let key, !force, maxAge > 0 {
            // 1) en memoria: las listas grandes (12.000 pelis) ya decodificadas, para no leerlas
            //    y decodificarlas de nuevo en cada pantalla (Películas, Seguir viendo, Buscar, Descargas…)
            if let e: (value: T, at: Date) = MemCache.shared.entry(key) {
                if Date().timeIntervalSince(e.at) < maxAge { return e.value }
                if stale, let cache {
                    refreshInBackground(T.self, action, extra, key: key, name: cache, maxAge: maxAge)
                    return e.value
                }
            }
            // 2) en disco
            if let hit = DiskCache.readDated(key, maxAge: stale ? .infinity : maxAge),
               let value = try? JSONDecoder().decode(T.self, from: hit.0) {
                MemCache.shared.set(key, value, at: hit.1)
                if Date().timeIntervalSince(hit.1) >= maxAge, let cache {
                    refreshInBackground(T.self, action, extra, key: key, name: cache, maxAge: maxAge)
                }
                return value
            }
        }
        do {
            return try await fetch(T.self, action, extra, key: key, maxAge: maxAge)
        } catch {
            // Sin red o el servidor falla: mejor la lista que ya teníamos (aunque sea vieja) que una pantalla de error.
            if let key, maxAge > 0, let data = DiskCache.read(key, maxAge: .infinity),
               let value = try? JSONDecoder().decode(T.self, from: data) {
                return value
            }
            throw error
        }
    }

    private func fetch<T: Decodable>(_ type: T.Type, _ action: String?, _ extra: [String: String],
                                     key: String?, maxAge: TimeInterval) async throws -> T {
        let (data, resp) = try await session.data(from: endpoint(action, extra))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw APIError.badResponse }
        if let key {
            DiskCache.write(key, data)
            if maxAge > 0 { MemCache.shared.set(key, value, at: Date()) }
        }
        return value
    }

    /// Descarga la lista nueva sin que nadie espere; si falla, se queda la vieja y no se reintenta
    /// hasta pasados 5 minutos (no insistir a un proveedor caído).
    private func refreshInBackground<T: Decodable>(_ type: T.Type, _ action: String?, _ extra: [String: String],
                                                   key: String, name: String, maxAge: TimeInterval) {
        Self.lock.lock()
        let busy = Self.refreshing.contains(key) || Date().timeIntervalSince(Self.lastTry[key] ?? .distantPast) < 300
        if !busy {
            Self.refreshing.insert(key)
            Self.lastTry[key] = Date()
        }
        Self.lock.unlock()
        guard !busy else { return }
        Task.detached(priority: .utility) { [self] in
            let ok = (try? await self.fetch(T.self, action, extra, key: key, maxAge: maxAge)) != nil
            Self.refreshDone(key)
            if ok {
                await MainActor.run { NotificationCenter.default.post(name: Self.listRefreshed, object: name) }
            }
        }
    }

    private static func refreshDone(_ key: String) {
        lock.lock()
        refreshing.remove(key)
        lock.unlock()
    }

    func authenticate() async throws -> AuthResponse {
        let r = try await get(AuthResponse.self, nil)
        guard r.auth == 1 else { throw APIError.auth }
        return r
    }

    func liveCategories(force: Bool = false) async throws -> [Category] {
        try await get(LossyArray<Category>.self, "get_live_categories", cache: "live_cat", maxAge: Self.listAge, force: force, stale: true).items
    }
    func liveStreams(force: Bool = false) async throws -> [LiveStream] {
        try await get(LossyArray<LiveStream>.self, "get_live_streams", cache: "live", maxAge: Self.listAge, force: force, stale: true).items
    }
    func vodCategories(force: Bool = false) async throws -> [Category] {
        try await get(LossyArray<Category>.self, "get_vod_categories", cache: "vod_cat", maxAge: Self.listAge, force: force, stale: true).items
    }
    func vodStreams(force: Bool = false) async throws -> [VodStream] {
        try await get(LossyArray<VodStream>.self, "get_vod_streams", cache: "vod", maxAge: Self.listAge, force: force, stale: true).items
    }
    func seriesCategories(force: Bool = false) async throws -> [Category] {
        try await get(LossyArray<Category>.self, "get_series_categories", cache: "series_cat", maxAge: Self.listAge, force: force, stale: true).items
    }
    func series(force: Bool = false) async throws -> [SeriesItem] {
        try await get(LossyArray<SeriesItem>.self, "get_series", cache: "series", maxAge: Self.listAge, force: force, stale: true).items
    }
    func seriesInfo(_ id: Int) async throws -> SeriesInfo {
        try await get(SeriesInfo.self, "get_series_info", ["series_id": String(id)], cache: "series_\(id)", maxAge: 6 * 3600)
    }
    func vodInfo(_ id: Int) async throws -> VodInfo {
        try await get(VodInfo.self, "get_vod_info", ["vod_id": String(id)], cache: "vodinfo_\(id)", maxAge: 7 * 24 * 3600)
    }
    /// Una sola petición al abrir el canal (nunca en bucle: el proveedor banea ráfagas).
    func shortEPG(_ streamId: Int) async throws -> [EPGEntry] {
        try await get(ShortEPG.self, "get_short_epg", ["stream_id": String(streamId), "limit": "3"]).entries
    }

    private func seg(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? s
    }
    func liveURL(_ id: Int) -> URL { URL(string: "\(base)/live/\(seg(user))/\(seg(pass))/\(id).ts")! }
    func movieURL(_ v: VodStream) -> URL { URL(string: "\(base)/movie/\(seg(user))/\(seg(pass))/\(v.id).\(v.ext)")! }
    func episodeURL(_ e: Episode) -> URL { URL(string: "\(base)/series/\(seg(user))/\(seg(pass))/\(e.id).\(e.ext)")! }
}
