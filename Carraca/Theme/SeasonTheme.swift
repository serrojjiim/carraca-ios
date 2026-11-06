import SwiftUI

// MARK: - Temas de temporada
//
// Se diseñan aquí (colores, lo que cae por la pantalla, saludo, fila especial) y se encienden
// desde el panel de Carraca (admin.php > Temas), que publica /tema.json:
//   modo "auto" (por fechas) | "fijo" (uno elegido, opcionalmente hasta una fecha) | "no".
// Sin conexión se usa la última copia guardada (y las fechas se miran en el propio iPhone).

struct SeasonTheme: Equatable {
    enum Motion: String { case snow, fall, flutter, confetti, sparkle, fireworks, off }

    let id: String
    let name: String
    let emoji: String
    /// Color de botones, pestañas, barras de progreso…
    let accentUI: UIColor
    /// Degradado del saludo y del brillo de arriba (oscuro: el texto va en blanco).
    let colors: [Color]
    /// Lo que cae / vuela (emoji). En la nieve son minoría: el resto son copos dibujados.
    let symbols: [String]
    let motion: Motion
    var message: String
    var railTitle: String
    var keywords: [String]
    /// Lo que se coloca encima (guirnaldas, emojis, imágenes): lo diseña el panel (Temas > Adornos).
    var ornaments: [Ornament] = []
    var particles = ParticleSettings()
    /// Pestañas en las que salen los adornos (vacío = todas).
    var screens: Set<String> = []

    var accent: Color { Color(uiColor: accentUI) }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// "#RRGGBB" (o "RRGGBB") del panel. nil si no es un color.
    convenience init?(hexString s: String) {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(hex: v)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }
}

extension SeasonTheme {
    /// Los temas que existen (el panel solo elige cuál y cuándo; los textos los puede cambiar).
    static let catalog: [String: SeasonTheme] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static let all: [SeasonTheme] = [
        SeasonTheme(id: "navidad", name: "Navidad", emoji: "🎄", accentUI: UIColor(hex: 0xE23B3B),
                    colors: [Color(hex: 0xB3121C), Color(hex: 0x0F6B3A)],
                    symbols: ["❄️"], motion: .snow,
                    message: "¡Feliz Navidad! Que no falten las pelis en casa 🎁",
                    railTitle: "Especial Navidad",
                    keywords: ["navidad", "navideñ", "christmas", "xmas", "santa claus", "papa noel", "grinch",
                               "reyes magos", "elfo", "reno", "muerdago", "polar express", "solo en casa",
                               "home alone", "nochebuena", "cuento de navidad", "scrooge"]),
        SeasonTheme(id: "halloween", name: "Halloween", emoji: "🎃", accentUI: UIColor(hex: 0xF26B1D),
                    colors: [Color(hex: 0x3A0D57), Color(hex: 0xB8460E)],
                    symbols: ["🦇", "🦇", "🦇", "🎃", "👻"], motion: .flutter,
                    message: "Noche de Halloween 🎃 ¿Te atreves con una de miedo?",
                    railTitle: "Noche de miedo",
                    keywords: ["halloween", "terror", "horror", "miedo", "zombi", "vampir", "bruja", "exorcis",
                               "fantasma", "poseid", "conjuro", "scream", "chucky", "pesadilla", "demonio",
                               "maldicion", "annabelle", "poltergeist", "slasher"]),
        SeasonTheme(id: "carnaval", name: "Carnaval", emoji: "🎭", accentUI: UIColor(hex: 0xE83E9C),
                    colors: [Color(hex: 0x5B1AA8), Color(hex: 0xC2186B)],
                    symbols: ["🎭", "🎉"], motion: .confetti,
                    message: "¡Feliz Carnaval! 🎭 Saca el disfraz",
                    railTitle: "Fiesta y disfraces",
                    keywords: ["carnaval", "carnival", "disfraz", "mascara", "fiesta", "musical", "baile", "circo"]),
        SeasonTheme(id: "primavera", name: "Primavera", emoji: "🌸", accentUI: UIColor(hex: 0xF0649A),
                    colors: [Color(hex: 0xB8336A), Color(hex: 0x3F8A47)],
                    symbols: ["🌸", "🌸", "🌸", "🌼", "🦋"], motion: .fall,
                    message: "Ha llegado la primavera 🌸",
                    railTitle: "Para enamorarse",
                    keywords: ["primavera", "spring", "amor", "romantic", "boda", "flores", "jardin", "cita"]),
        SeasonTheme(id: "verano", name: "Verano", emoji: "☀️", accentUI: UIColor(hex: 0xFF6F61),
                    colors: [Color(hex: 0x0A5E9C), Color(hex: 0x0E8F8F)],
                    symbols: [], motion: .sparkle,
                    message: "¡Feliz verano! ☀️ Pelis para refrescarse",
                    railTitle: "Pelis de verano",
                    keywords: ["verano", "summer", "playa", "beach", "vacaciones", "surf", "tiburon", "shark",
                               "piscina", "isla", "crucero", "tropical"]),
        SeasonTheme(id: "otono", name: "Otoño", emoji: "🍂", accentUI: UIColor(hex: 0xD9822B),
                    colors: [Color(hex: 0x7A3010), Color(hex: 0xA8591A)],
                    symbols: ["🍂", "🍁", "🍂", "🍁", "🍃"], motion: .fall,
                    message: "Llega el otoño 🍂 Manta, sofá y peli",
                    railTitle: "Misterio para el otoño",
                    keywords: ["otoño", "autumn", "misterio", "mystery", "thriller", "crimen", "detective",
                               "asesin", "agatha", "sherlock"]),
        SeasonTheme(id: "invierno", name: "Invierno", emoji: "❄️", accentUI: UIColor(hex: 0x5AB0F0),
                    colors: [Color(hex: 0x163E6E), Color(hex: 0x2F6EA8)],
                    symbols: ["❄️"], motion: .snow,
                    message: "Hace frío fuera ❄️ Dentro, cine",
                    railTitle: "Historias de invierno",
                    keywords: ["invierno", "winter", "nieve", "snow", "frozen", "hielo", "polar", "artico",
                               "everest", "glacia"]),
    ]
}

/// /tema.json del panel.
struct ThemeConfig: Decodable {
    struct Texts {
        var message: String?; var rail: String?; var keywords: [String]?
        var ornaments: [Ornament]?; var particles: ParticleSettings?; var screens: [String]?
    }
    struct Span { let id: String; let from: String; let to: String }

    var mode = "no"
    var fixed: String?
    var fixedUntil: String?
    /// 0 = sin decoración animada, 1 = suave, 2 = normal.
    var effects = 2
    var texts: [String: Texts] = [:]
    var calendar: [Span] = []
    /// Temas creados en el panel ("Crear tema"): el diseño entero viene en el JSON.
    var custom: [String: SeasonTheme] = [:]
    /// Momentos con día y hora (Nochevieja, un partido…).
    var moments: [ThemeMoment] = []

    enum CodingKeys: String, CodingKey { case modo, fijo, fijo_hasta, efectos, temas, calendario, custom, momentos }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        mode = c.flexString(.modo) ?? "no"
        fixed = c.flexString(.fijo)
        fixedUntil = c.flexString(.fijo_hasta).flatMap { $0.isEmpty ? nil : $0 }
        effects = max(0, min(2, c.flexInt(.efectos) ?? 2))
        if let t = try? c.decode([String: JSONValue].self, forKey: .temas) {
            for (id, v) in t {
                guard case .object(let o) = v else { continue }
                var x = Texts()
                if case .string(let s)? = o["msg"] { x.message = s }
                if case .string(let s)? = o["fila"] { x.rail = s }
                if case .array(let a)? = o["palabras"] {
                    x.keywords = a.compactMap { v -> String? in
                        if case .string(let s) = v { return s }
                        return nil
                    }
                }
                if let a = o["adornos"]?.arr { x.ornaments = Ornament.parse(a) }
                if let p = o["particulas"]?.obj { x.particles = ParticleSettings.parse(p) }
                if let a = o["pantallas"]?.arr { x.screens = a.compactMap(\.str) }
                texts[id] = x
            }
        }
        if let list = try? c.decode([JSONValue].self, forKey: .calendario) {
            for v in list {
                guard case .object(let o) = v, case .string(let id)? = o["id"],
                      case .string(let a)? = o["desde"], case .string(let b)? = o["hasta"] else { continue }
                calendar.append(Span(id: id, from: a, to: b))
            }
        }
        if let list = try? c.decode([String: JSONValue].self, forKey: .custom) {
            for (id, v) in list {
                guard case .object(let o) = v, let t = Self.customTheme(id: id, o) else { continue }
                custom[id] = t
            }
        }
        if let list = try? c.decode([JSONValue].self, forKey: .momentos) {
            moments = ThemeMoment.parse(list)
        }
    }

    /// {"nombre", "emoji", "acento": "#RRGGBB", "colores": ["#…", "#…"], "efecto", "caen": ["🎉", …]}
    private static func customTheme(id: String, _ o: [String: JSONValue]) -> SeasonTheme? {
        func str(_ k: String) -> String? { if case .string(let s)? = o[k] { return s }; return nil }
        func strs(_ k: String) -> [String] {
            guard case .array(let a)? = o[k] else { return [] }
            return a.compactMap { v -> String? in
                if case .string(let s) = v { return s }
                return nil
            }
        }
        guard let accent = str("acento").flatMap(UIColor.init(hexString:)) else { return nil }
        var colors = strs("colores").compactMap(UIColor.init(hexString:)).map { Color(uiColor: $0) }
        if colors.isEmpty { colors = [Color(uiColor: accent)] }
        if colors.count == 1 { colors.append(colors[0]) }
        let motion: SeasonTheme.Motion
        switch str("efecto") ?? "" {
        case "snow": motion = .snow
        case "fall": motion = .fall
        case "fly": motion = .flutter
        case "confetti": motion = .confetti
        case "rise": motion = .sparkle
        case "fireworks": motion = .fireworks
        default: motion = .off
        }
        // Lo que cae: emojis cortos (un emoji puede ocupar varios "caracteres" de Swift si lleva tono, etc.)
        let symbols = Array(strs("caen").map { String($0.prefix(2)) }.filter { !$0.isEmpty }.prefix(8))
        let name = String((str("nombre") ?? "Tema").prefix(30))
        return SeasonTheme(id: id, name: name,
                           emoji: String((str("emoji") ?? "✨").prefix(2)), accentUI: accent,
                           colors: Array(colors.prefix(2)), symbols: symbols,
                           motion: (motion == .fall || motion == .flutter) && symbols.isEmpty ? .snow : motion,
                           message: "", railTitle: "Especial " + name, keywords: [])
    }

    static let day: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Qué tema toca hoy (en el orden del panel: primero las fiestas, luego las estaciones).
    func activeID(on date: Date) -> String? {
        let today = Self.day.string(from: date)
        if mode == "fijo", let f = fixed, !f.isEmpty {
            if let until = fixedUntil, today > until { return scheduled(today) }
            return f
        }
        return mode == "auto" ? scheduled(today) : nil
    }

    private func scheduled(_ today: String) -> String? {
        calendar.first { $0.from <= today && today <= $0.to }?.id
    }
}

// MARK: - Fila especial ("Especial Navidad", "Noche de miedo"…)

extension SeasonTheme {
    static let railCategoryID = "__tema__"
    var railCategory: Category { Category(id: Self.railCategoryID, name: railTitle) }
}

/// Títulos que encajan con las palabras del tema (en el nombre o en la categoría).
/// Las palabras cortas (≤3 letras) tienen que ir sueltas, para que "it" no cuele en "Little".
func seasonalPicks<T>(_ list: [T], keywords: [String], text: (T) -> String, limit: Int) async -> [T] {
    let keys = keywords.map { $0.searchKey.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !keys.isEmpty else { return [] }
    let long = keys.filter { $0.count > 3 }
    let short = keys.filter { $0.count <= 3 }.map { " \($0) " }
    var out: [T] = []
    for it in list {
        let t = " " + text(it).searchKey + " "
        if long.contains(where: { t.contains($0) }) || short.contains(where: { t.contains($0) }) {
            out.append(it)
            if out.count >= limit { break }
        }
    }
    return out
}
