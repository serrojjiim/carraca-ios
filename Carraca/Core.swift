import Foundation
import Security

// MARK: - Configuración

enum AppConfig {
    /// Panel propio (config.json, Seguir viendo, Deportes). El mismo que usa la app Android.
    static let panel = "https://carracaservice.duckdns.org"
    static var configURL: URL { URL(string: panel + "/config.json")! }
    static var resumeURL: URL { URL(string: panel + "/resume.php")! }
    static var sportsURL: URL { URL(string: panel + "/deportes_html.php")! }
    /// Respaldo por si config.json no responde.
    static let fallbackServer = "http://82.165.142.230"

    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
}

/// config.json del panel.
struct RemoteConfig: Decodable {
    var baseURL: String?
    var baseURL2: String?
    var iosVersionCode: Int?
    var iosInstallURL: String?

    enum CodingKeys: String, CodingKey { case base_url, base_url_2, ios_version_code, ios_install_url }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        baseURL = c.flexString(.base_url)
        baseURL2 = c.flexString(.base_url_2)
        iosVersionCode = c.flexInt(.ios_version_code)
        iosInstallURL = c.flexString(.ios_install_url)
    }

    /// Servidores Carraca en orden de preferencia.
    var servers: [String] {
        [baseURL, baseURL2].compactMap { $0 }.map(ServerURL.normalize).filter { !$0.isEmpty }
    }
}

enum ServerURL {
    /// "midominio.com:8080/" -> "http://midominio.com:8080"
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        let low = s.lowercased()
        if !low.hasPrefix("http://") && !low.hasPrefix("https://") { s = "http://" + s }
        for suffix in ["/player_api.php", "/get.php"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

// MARK: - JSON tolerante (los paneles Xtream mezclan números y textos)

extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let v = try? decodeIfPresent(String.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return String(v) }
        return nil
    }

    func flexInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            if let i = Int(s) { return i }
            if let d = Double(s) { return Int(d) }
        }
        return nil
    }

    func flexDouble(_ key: Key) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

/// Cualquier valor JSON (para poder saltar elementos que no se entienden).
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "valor JSON desconocido") }
    }
}

/// Array que descarta los elementos rotos en vez de fallar entero.
struct LossyArray<T: Decodable>: Decodable {
    var items: [T] = []

    init(from d: Decoder) throws {
        guard var c = try? d.unkeyedContainer() else { return }
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) {
                items.append(v)
            } else if (try? c.decode(JSONValue.self)) == nil {
                break
            }
        }
    }
}

extension String {
    /// "ES - Ice Age 4 (2012)" -> "Ice Age 4 (2012)"
    var cleanTitle: String {
        if let r = range(of: #"^[A-Z]{2,4}\s*[-|:]\s+"#, options: .regularExpression) {
            return String(self[r.upperBound...])
        }
        return self
    }

    /// "Friends (US) - S01E20 - El del dentista" -> "Friends (US)"
    var seriesBaseName: String {
        if let r = range(of: #"\s*-?\s*S\d{1,2}\s*E\d{1,3}.*$"#, options: .regularExpression) {
            return String(self[..<r.lowerBound])
        }
        return self
    }
}

// MARK: - Modelos Xtream

struct Category: Decodable, Identifiable, Hashable {
    let id: String
    let name: String

    static let all = Category(id: "*", name: "Todos")

    init(id: String, name: String) { self.id = id; self.name = name }

    enum CodingKeys: String, CodingKey { case category_id, category_name }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.flexString(.category_id) ?? ""
        name = c.flexString(.category_name) ?? "Sin nombre"
    }
}

struct LiveStream: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String?
    let categoryId: String
    /// Solo en listas M3U: URL directa del canal.
    var directURL: URL? = nil

    init(id: Int, name: String, icon: String?, categoryId: String, directURL: URL?) {
        self.id = id
        self.name = name
        self.icon = icon
        self.categoryId = categoryId
        self.directURL = directURL
    }

    enum CodingKeys: String, CodingKey { case stream_id, name, stream_icon, category_id }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let id = c.flexInt(.stream_id) else {
            throw DecodingError.dataCorruptedError(forKey: .stream_id, in: c, debugDescription: "sin id")
        }
        self.id = id
        name = c.flexString(.name) ?? "Canal \(id)"
        icon = c.flexString(.stream_icon).flatMap { $0.isEmpty ? nil : $0 }
        categoryId = c.flexString(.category_id) ?? ""
    }
}

struct VodStream: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String?
    let categoryId: String
    let ext: String
    let rating: String?

    enum CodingKeys: String, CodingKey { case stream_id, name, stream_icon, category_id, container_extension, rating }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let id = c.flexInt(.stream_id) else {
            throw DecodingError.dataCorruptedError(forKey: .stream_id, in: c, debugDescription: "sin id")
        }
        self.id = id
        name = c.flexString(.name) ?? "Película \(id)"
        icon = c.flexString(.stream_icon).flatMap { $0.isEmpty ? nil : $0 }
        categoryId = c.flexString(.category_id) ?? ""
        ext = c.flexString(.container_extension).flatMap { $0.isEmpty ? nil : $0 } ?? "mp4"
        rating = c.flexString(.rating)
    }
}

struct SeriesItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let cover: String?
    let categoryId: String
    let plot: String?
    let genre: String?
    let releaseDate: String?

    enum CodingKeys: String, CodingKey { case series_id, name, cover, category_id, plot, genre, releaseDate }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let id = c.flexInt(.series_id) else {
            throw DecodingError.dataCorruptedError(forKey: .series_id, in: c, debugDescription: "sin id")
        }
        self.id = id
        name = c.flexString(.name) ?? "Serie \(id)"
        cover = c.flexString(.cover).flatMap { $0.isEmpty ? nil : $0 }
        categoryId = c.flexString(.category_id) ?? ""
        plot = c.flexString(.plot)
        genre = c.flexString(.genre)
        releaseDate = c.flexString(.releaseDate)
    }
}

struct Episode: Decodable, Identifiable, Hashable {
    let id: String
    let number: Int
    let season: Int
    let title: String
    let ext: String
    let image: String?
    let durationSecs: Int?
    let plot: String?

    enum CodingKeys: String, CodingKey { case id, episode_num, season, title, container_extension, info }
    enum InfoKeys: String, CodingKey { case movie_image, duration_secs, plot }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let id = c.flexString(.id) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "sin id")
        }
        self.id = id
        number = c.flexInt(.episode_num) ?? 0
        season = c.flexInt(.season) ?? 0
        title = c.flexString(.title) ?? "Episodio"
        ext = c.flexString(.container_extension).flatMap { $0.isEmpty ? nil : $0 } ?? "mp4"
        if let i = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            image = i.flexString(.movie_image)
            durationSecs = i.flexInt(.duration_secs)
            plot = i.flexString(.plot)
        } else {
            image = nil
            durationSecs = nil
            plot = nil
        }
    }
}

struct SeriesInfo: Decodable {
    var episodes: [Int: [Episode]] = [:]
    var plot: String?
    var cover: String?

    var seasons: [Int] { episodes.keys.sorted() }

    enum CodingKeys: String, CodingKey { case episodes, info }
    enum InfoKeys: String, CodingKey { case plot, cover }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let dict = try? c.decode([String: LossyArray<Episode>].self, forKey: .episodes) {
            for (k, v) in dict {
                if let s = Int(k) { episodes[s] = v.items.sorted { $0.number < $1.number } }
            }
        }
        if let i = try? c.nestedContainer(keyedBy: InfoKeys.self, forKey: .info) {
            plot = i.flexString(.plot)
            cover = i.flexString(.cover)
        }
    }
}

struct VodInfo: Decodable {
    var plot: String?
    var cast: String?
    var director: String?
    var genre: String?
    var release: String?
    var duration: String?
    var image: String?

    enum CodingKeys: String, CodingKey { case info }
    enum K: String, CodingKey { case plot, cast, director, genre, releasedate, duration, movie_image }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        if let i = try? c.nestedContainer(keyedBy: K.self, forKey: .info) {
            plot = i.flexString(.plot)
            cast = i.flexString(.cast)
            director = i.flexString(.director)
            genre = i.flexString(.genre)
            release = i.flexString(.releasedate)
            duration = i.flexString(.duration)
            image = i.flexString(.movie_image)
        }
    }
}

struct AuthResponse: Decodable {
    let auth: Int
    let status: String?
    let expDate: Date?
    let maxConnections: Int?

    enum CodingKeys: String, CodingKey { case user_info }
    enum U: String, CodingKey { case auth, status, exp_date, max_connections }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let u = try c.nestedContainer(keyedBy: U.self, forKey: .user_info)
        auth = u.flexInt(.auth) ?? 0
        status = u.flexString(.status)
        expDate = u.flexDouble(.exp_date).map { Date(timeIntervalSince1970: $0) }
        maxConnections = u.flexInt(.max_connections)
    }
}

struct EPGEntry: Decodable, Identifiable {
    let id = UUID()
    let title: String
    let start: Date?
    let end: Date?

    enum CodingKeys: String, CodingKey { case title, start_timestamp, stop_timestamp }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let raw = c.flexString(.title) ?? ""
        title = Data(base64Encoded: raw).flatMap { String(data: $0, encoding: .utf8) } ?? raw
        start = c.flexDouble(.start_timestamp).map { Date(timeIntervalSince1970: $0) }
        end = c.flexDouble(.stop_timestamp).map { Date(timeIntervalSince1970: $0) }
    }
}

struct ShortEPG: Decodable {
    let entries: [EPGEntry]
    enum CodingKeys: String, CodingKey { case epg_listings }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        entries = (try? c.decode(LossyArray<EPGEntry>.self, forKey: .epg_listings))?.items ?? []
    }
}

/// Elemento de "Seguir viendo" (mismo formato que resume.php del panel / app Android).
struct ResumeItem: Codable, Identifiable, Hashable {
    let type: String
    let name: String
    let itemId: String
    let url: String
    let season: Int
    let episode: Int
    let position: Int
    let duration: Int
    let pro: Int
    let ts: Int

    var id: String { type + "|" + name }

    enum CodingKeys: String, CodingKey { case type, name, id, url, season, episode, position, duration, pro, ts }

    init(type: String, name: String, itemId: String, url: String, season: Int, episode: Int,
         position: Int, duration: Int, pro: Int, ts: Int) {
        self.type = type; self.name = name; self.itemId = itemId; self.url = url
        self.season = season; self.episode = episode; self.position = position
        self.duration = duration; self.pro = pro; self.ts = ts
    }

    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(name, forKey: .name)
        try c.encode(itemId, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(season, forKey: .season)
        try c.encode(episode, forKey: .episode)
        try c.encode(position, forKey: .position)
        try c.encode(duration, forKey: .duration)
        try c.encode(pro, forKey: .pro)
        try c.encode(ts, forKey: .ts)
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        type = c.flexString(.type) ?? "movie"
        name = c.flexString(.name) ?? ""
        itemId = c.flexString(.id) ?? ""
        url = c.flexString(.url) ?? ""
        season = c.flexInt(.season) ?? 0
        episode = c.flexInt(.episode) ?? 0
        position = c.flexInt(.position) ?? 0
        duration = c.flexInt(.duration) ?? 0
        pro = c.flexInt(.pro) ?? 0
        ts = c.flexInt(.ts) ?? 0
    }
}

// MARK: - Listas M3U

enum M3U {
    /// #EXTINF:-1 tvg-logo="..." group-title="Deportes",Nombre  ->  siguiente línea = URL
    static func parse(_ text: String) -> [LiveStream] {
        var out: [LiveStream] = []
        var name = "", logo: String?, group = "Sin categoría"
        var pending = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") {
                logo = attr("tvg-logo", in: line)
                group = attr("group-title", in: line) ?? "Sin categoría"
                if let comma = line.lastIndex(of: ",") {
                    name = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    name = ""
                }
                pending = true
            } else if !line.hasPrefix("#"), pending, let url = URL(string: line) {
                let n = name.isEmpty ? "Canal \(out.count + 1)" : name
                out.append(LiveStream(id: out.count + 1, name: n, icon: (logo?.isEmpty ?? true) ? nil : logo,
                                      categoryId: group, directURL: url))
                pending = false
            }
        }
        return out
    }

    private static func attr(_ key: String, in line: String) -> String? {
        guard let r = line.range(of: key + "=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}

// MARK: - Seguir viendo local (versión genérica: se guarda solo en el dispositivo)

enum LocalResume {
    private static let key = "carraca.resume"

    static func load() -> [ResumeItem] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([ResumeItem].self, from: d) else { return [] }
        return list
    }

    static func upsert(_ item: ResumeItem) {
        var list = load().filter { !($0.type == item.type && $0.name == item.name) }
        if item.pro < 95 { list.insert(item, at: 0) }
        if let d = try? JSONEncoder().encode(Array(list.prefix(20))) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

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

    func get<T: Decodable>(_ type: T.Type, _ action: String?, _ extra: [String: String] = [:],
                           cache: String? = nil, maxAge: TimeInterval = 0, force: Bool = false) async throws -> T {
        let key = cache.map { cachePrefix + "_" + $0 }
        if let key, !force, maxAge > 0, let data = DiskCache.read(key, maxAge: maxAge),
           let value = try? JSONDecoder().decode(T.self, from: data) {
            return value
        }
        let (data, resp) = try await session.data(from: endpoint(action, extra))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw APIError.http(code) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw APIError.badResponse }
        if let key { DiskCache.write(key, data) }
        return value
    }

    func authenticate() async throws -> AuthResponse {
        let r = try await get(AuthResponse.self, nil)
        guard r.auth == 1 else { throw APIError.auth }
        return r
    }

    func liveCategories(force: Bool = false) async throws -> [Category] {
        try await get(LossyArray<Category>.self, "get_live_categories", cache: "live_cat", maxAge: Self.listAge, force: force).items
    }
    func liveStreams(force: Bool = false) async throws -> [LiveStream] {
        try await get(LossyArray<LiveStream>.self, "get_live_streams", cache: "live", maxAge: Self.listAge, force: force).items
    }
    func vodCategories(force: Bool = false) async throws -> [Category] {
        try await get(LossyArray<Category>.self, "get_vod_categories", cache: "vod_cat", maxAge: Self.listAge, force: force).items
    }
    func vodStreams(force: Bool = false) async throws -> [VodStream] {
        try await get(LossyArray<VodStream>.self, "get_vod_streams", cache: "vod", maxAge: Self.listAge, force: force).items
    }
    func seriesCategories(force: Bool = false) async throws -> [Category] {
        try await get(LossyArray<Category>.self, "get_series_categories", cache: "series_cat", maxAge: Self.listAge, force: force).items
    }
    func series(force: Bool = false) async throws -> [SeriesItem] {
        try await get(LossyArray<SeriesItem>.self, "get_series", cache: "series", maxAge: Self.listAge, force: force).items
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
        let f = file(key)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
              let mod = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mod) < maxAge else { return nil }
        return try? Data(contentsOf: f)
    }

    static func write(_ key: String, _ data: Data) {
        try? data.write(to: file(key), options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
}

// MARK: - Credenciales (Llavero de iOS)

struct Credentials: Codable, Equatable {
    var server: String
    var user: String
    var pass: String
    /// true si el usuario dejó el servidor vacío (servidor Carraca, se actualiza solo desde config.json).
    /// Solo existe en la versión privada (Ad Hoc).
    var usesDefaultServer: Bool
    /// Si no es nil, la cuenta es una lista M3U (server/user/pass vacíos).
    var m3u: String? = nil
}

enum Keychain {
    private static let base: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.carraca.smarter.login",
        kSecAttrAccount as String: "creds",
    ]

    static func save(_ c: Credentials) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Credentials? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return try? JSONDecoder().decode(Credentials.self, from: d)
    }

    static func delete() {
        SecItemDelete(base as CFDictionary)
    }
}
