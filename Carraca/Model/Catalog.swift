import Foundation

// MARK: - Modelos Xtream

struct Category: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    /// Nombre limpio + etiqueta (RAW, 4K…), calculado una vez (no en cada repintado).
    let label: CategoryLabel

    static let all = Category(id: "*", name: "Todos")

    init(id: String, name: String) { self.id = id; self.name = name; label = name.categoryLabel }

    enum CodingKeys: String, CodingKey { case category_id, category_name }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = c.flexString(.category_id) ?? ""
        name = c.flexString(.category_name) ?? "Sin nombre"
        label = name.categoryLabel
    }
}

struct LiveStream: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    let icon: String?
    let categoryId: String
    /// Nombre limpio + etiqueta (calculado una vez).
    let label: CategoryLabel
    /// Solo en listas M3U: URL directa del canal.
    var directURL: URL? = nil
    /// Id del canal en la guía XMLTV (para "ahora / después").
    var epgId: String? = nil

    /// "Canales" que solo hacen de título de sección ("#### TELEFÓNICA ####", con bandera de icono).
    var isSeparator: Bool { name.range(of: #"#{3,}|={4,}|-{5,}|\*{4,}"#, options: .regularExpression) != nil }

    init(id: Int, name: String, icon: String?, categoryId: String, directURL: URL?) {
        self.id = id
        self.name = name
        self.icon = icon
        self.categoryId = categoryId
        self.directURL = directURL
        label = name.channelLabel
    }

    enum CodingKeys: String, CodingKey { case stream_id, name, stream_icon, category_id, epg_channel_id }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let id = c.flexInt(.stream_id) else {
            throw DecodingError.dataCorruptedError(forKey: .stream_id, in: c, debugDescription: "sin id")
        }
        self.id = id
        name = c.flexString(.name) ?? "Canal \(id)"
        icon = c.flexString(.stream_icon).flatMap { $0.isEmpty ? nil : $0 }
        categoryId = c.flexString(.category_id) ?? ""
        epgId = c.flexString(.epg_channel_id).flatMap { $0.isEmpty ? nil : $0 }
        label = name.channelLabel
    }
}

struct VodStream: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    /// Título limpio ("ES - Ice Age 4" -> "Ice Age 4") y año, calculados una vez al leer la lista.
    let title: String
    let year: Int?
    let icon: String?
    let categoryId: String
    let ext: String
    let rating: String?
    /// Fecha de alta en el proveedor (para "Recién añadidas").
    let added: Int
    let trailer: String?

    var score: Double { Double(rating ?? "") ?? 0 }

    enum CodingKeys: String, CodingKey { case stream_id, name, stream_icon, category_id, container_extension, rating, added, trailer }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        guard let id = c.flexInt(.stream_id) else {
            throw DecodingError.dataCorruptedError(forKey: .stream_id, in: c, debugDescription: "sin id")
        }
        self.id = id
        name = c.flexString(.name) ?? "Película \(id)"
        title = name.cleanTitle
        year = name.yearGuess
        icon = c.flexString(.stream_icon).flatMap { $0.isEmpty ? nil : $0 }
        categoryId = c.flexString(.category_id) ?? ""
        ext = c.flexString(.container_extension).flatMap { $0.isEmpty ? nil : $0 } ?? "mp4"
        rating = c.flexString(.rating)
        added = c.flexInt(.added) ?? 0
        trailer = c.flexString(.trailer).flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct SeriesItem: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String
    /// Título limpio, año y géneros, calculados una vez al leer la lista.
    let title: String
    let year: Int?
    let genres: [String]
    let cover: String?
    let categoryId: String
    let plot: String?
    let genre: String?
    let releaseDate: String?
    /// Imagen horizontal grande (portada destacada).
    let backdrop: String?
    let updated: Int
    let trailer: String?
    let rating: String?

    var score: Double { Double(rating ?? "") ?? 0 }

    enum CodingKeys: String, CodingKey { case series_id, name, cover, category_id, plot, genre, releaseDate, backdrop_path, last_modified, youtube_trailer, rating }

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
        // backdrop_path suele venir como lista de URLs, a veces como texto.
        let bd = (try? c.decodeIfPresent([String].self, forKey: .backdrop_path))?.first ?? c.flexString(.backdrop_path)
        backdrop = bd.flatMap { $0.hasPrefix("http") ? $0 : nil }
        updated = c.flexInt(.last_modified) ?? 0
        trailer = c.flexString(.youtube_trailer).flatMap { $0.isEmpty ? nil : $0 }
        rating = c.flexString(.rating)
        title = name.cleanTitle
        year = (releaseDate ?? "").yearGuess ?? name.yearGuess
        // géneros sueltos ("Drama, Comedia" -> ["Drama", "Comedia"])
        genres = (genre ?? "").split(whereSeparator: { ",/".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
    /// Imagen horizontal grande (fondo de la ficha).
    var backdrop: String?

    var seasons: [Int] { episodes.keys.sorted() }

    /// Todos los capítulos en orden (temporada, capítulo).
    var allEpisodes: [(Int, Episode)] { seasons.flatMap { n in (episodes[n] ?? []).map { (n, $0) } } }

    /// El capítulo que va después de `ep` (pasando a la temporada siguiente si hace falta).
    func episode(after ep: Episode, season s: Int) -> (Int, Episode)? {
        let all = allEpisodes
        guard let i = all.firstIndex(where: { $0.0 == s && $0.1.id == ep.id }), i + 1 < all.count else { return nil }
        return all[i + 1]
    }

    enum CodingKeys: String, CodingKey { case episodes, info }
    enum InfoKeys: String, CodingKey { case plot, cover, backdrop_path }

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
            let bd = (try? i.decodeIfPresent([String].self, forKey: .backdrop_path))?.first ?? i.flexString(.backdrop_path)
            backdrop = bd.flatMap { $0.hasPrefix("http") ? $0 : nil }
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
    var trailer: String?
    /// Imagen horizontal grande de la peli (fondo de la ficha).
    var backdrop: String?

    /// Reparto como lista ("A, B, C" -> ["A", "B", "C"]).
    var castList: [String] {
        (cast ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    enum CodingKeys: String, CodingKey { case info }
    enum K: String, CodingKey { case plot, cast, director, genre, releasedate, duration, movie_image, youtube_trailer, backdrop_path }

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
            trailer = i.flexString(.youtube_trailer).flatMap { $0.isEmpty ? nil : $0 }
            let bd = (try? i.decodeIfPresent([String].self, forKey: .backdrop_path))?.first ?? i.flexString(.backdrop_path)
            backdrop = bd.flatMap { $0.hasPrefix("http") ? $0 : nil }
        }
    }
}

/// Enlace de un tráiler: el proveedor da el id de YouTube o la URL entera.
func trailerURL(_ raw: String?) -> URL? {
    guard let r = raw?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return nil }
    if r.lowercased().hasPrefix("http") { return URL(string: r) }
    guard r.range(of: #"^[A-Za-z0-9_-]{6,20}$"#, options: .regularExpression) != nil else { return nil }
    return URL(string: "https://www.youtube.com/watch?v=" + r)
}

/// Programa de la guía ("ahora / después").
struct GuideEntry: Hashable {
    let start: Date
    let end: Date
    let title: String
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

    init(title: String, start: Date?, end: Date?) {
        self.title = title
        self.start = start
        self.end = end
    }

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
