import SwiftUI

// MARK: - Temas de temporada
//
// Se diseñan aquí (colores, lo que cae por la pantalla, saludo, fila especial) y se encienden
// desde el panel de Carraca (admin.php > Temas), que publica /tema.json:
//   modo "auto" (por fechas) | "fijo" (uno elegido, opcionalmente hasta una fecha) | "no".
// Sin conexión se usa la última copia guardada (y las fechas se miran en el propio iPhone).

struct SeasonTheme: Equatable {
    enum Motion: String { case snow, fall, flutter, confetti, sparkle, off }

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
    struct Texts { var message: String?; var rail: String?; var keywords: [String]? }
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

    enum CodingKeys: String, CodingKey { case modo, fijo, fijo_hasta, efectos, temas, calendario, custom }

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

    private var config: ThemeConfig?
    private var lastFetch = Date.distantPast

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

    private func recompute() {
        var t = config?.activeID(on: Date()).flatMap { SeasonTheme.catalog[$0] ?? config?.custom[$0] }
        if var x = t, let o = config?.texts[x.id] {
            if let m = o.message { x.message = m }
            if let r = o.rail, !r.isEmpty { x.railTitle = r }
            if let k = o.keywords { x.keywords = k }
            t = x
        }
        if t != current { current = t }
        let e = config?.effects ?? 2
        if e != effects { effects = e }
        applyWindowTint()
    }

    /// Lo de UIKit (alertas, menús, barra de pestañas) también con el color del tema.
    func applyWindowTint() {
        let c = current?.accentUI ?? UIColor(named: "AccentColor")
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for w in scene.windows { w.tintColor = c }
        }
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

// MARK: - Color del tema en toda la app

private struct SeasonTint: ViewModifier {
    @ObservedObject private var theme = ThemeStore.shared

    func body(content: Content) -> some View {
        let c = theme.current?.accent ?? Color("AccentColor")
        content.tint(c).accentColor(c)
    }
}

extension View {
    /// Color del tema de temporada (o el normal de Carraca). Va también en cada hoja / pantalla completa.
    func seasonTint() -> some View { modifier(SeasonTint()) }
}

// MARK: - Saludo de arriba

struct SeasonBanner: View {
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage("carraca.tema.cerrado") private var closed = ""
    @AppStorage(ThemeStore.decorKey) private var decor = true
    /// Por dónde entra / sale (arriba en iPhone; abajo en iPad, donde las pestañas van arriba).
    var edge: Edge = .top

    var body: some View {
        if decor, let t = theme.current, !t.message.isEmpty, closed != theme.bannerKey {
            HStack(spacing: 10) {
                Text(t.emoji).font(.title3)
                Text(t.message).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 6)
                Button { withAnimation(.easeInOut(duration: 0.25)) { closed = theme.bannerKey } } label: {
                    Image(systemName: "xmark").font(.caption.bold()).padding(6)
                }
                .accessibilityLabel("Cerrar saludo")
            }
            .foregroundStyle(.white)
            .padding(.leading, 14).padding(.trailing, 8).padding(.vertical, 7)
            .background(LinearGradient(colors: t.colors, startPoint: .leading, endPoint: .trailing))
            .transition(.move(edge: edge).combined(with: .opacity))
        }
    }
}

// MARK: - Decoración animada (nieve, hojas, murciélagos, confeti…)

/// Capa por encima de todo, sin tocar los toques: brillo del color del tema arriba y lo que cae.
/// Solo ocupa la parte de arriba de la pantalla (se desvanece hacia la mitad) para no tapar las listas.
struct SeasonDecor: View {
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage(ThemeStore.decorKey) private var decor = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase

    var body: some View {
        if decor, theme.effects > 0, let t = theme.current {
            ZStack(alignment: .top) {
                LinearGradient(colors: [t.colors[0].opacity(0.30), t.colors[t.colors.count - 1].opacity(0.10), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
                if t.motion != .off && !reduceMotion && !ProcessInfo.processInfo.isLowPowerModeEnabled {
                    ParticleField(theme: t, count: theme.effects >= 2 ? 24 : 11,
                                  paused: theme.paused || phase != .active)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }
}

/// Partículas dibujadas en un Canvas (30 fotogramas por segundo, se para con el reproductor abierto).
/// Cada partícula sale de su número (sin estado): mismo dibujo siempre, nada que guardar.
struct ParticleField: View {
    let theme: SeasonTheme
    let count: Int
    let paused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { tl in
            Canvas { ctx, size in
                draw(&ctx, size, tl.date.timeIntervalSinceReferenceDate)
            } symbols: {
                ForEach(Array(theme.symbols.enumerated()), id: \.offset) { i, s in
                    Text(s).font(.system(size: 22)).tag(i)
                }
            }
        }
    }

    /// Número "aleatorio" fijo para cada partícula (0…1).
    private static func rnd(_ i: Int, _ k: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + k * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = Double(size.width)
        let band = max(240, Double(size.height) * 0.48)
        let nSym = theme.symbols.count
        for i in 0..<count {
            let r = { (k: Double) -> Double in Self.rnd(i, k) }
            switch theme.motion {
            case .snow, .fall:
                let dur = (theme.motion == .snow ? 9 : 12) + r(1) * 9
                let p = (t / dur + r(2)).truncatingRemainder(dividingBy: 1)
                let y = -24 + p * (band + 24)
                let x = r(3) * w + sin(t * (0.35 + r(4) * 0.6) + r(5) * 6.28) * (10 + r(6) * 26)
                let fade = min(1, p * 7) * pow(1 - p, 1.3)
                let useSymbol = nSym > 0 && (theme.motion == .fall || r(8) < 0.2)
                if useSymbol {
                    let s = (theme.motion == .fall ? 15 : 11) + r(7) * 10
                    symbol(&ctx, Int(r(9) * Double(nSym)) % nSym, x: x, y: y, size: s,
                           angle: t * (r(10) - 0.5) * 1.8 + r(11) * 6.28, opacity: 0.8 * fade)
                } else {
                    let d = 2 + r(7) * 3.5
                    ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)),
                             with: .color(.white.opacity(0.75 * fade)))
                }
            case .flutter:
                // murciélagos (y alguna calabaza / fantasma) cruzando de lado a lado, aleteando
                let dir: Double = r(10) < 0.5 ? 1 : -1
                let dur = 13 + r(1) * 11
                let p = (t / dur + r(2)).truncatingRemainder(dividingBy: 1)
                let x = dir > 0 ? -30 + p * (w + 60) : w + 30 - p * (w + 60)
                let y = 40 + r(3) * band * 0.75 + sin(t * (1.4 + r(4) * 1.8) + r(5) * 6.28) * 14
                let k = nSym > 0 ? Int(r(9) * Double(nSym)) % nSym : 0
                let flap = theme.symbols.indices.contains(k) && theme.symbols[k] == "🦇"
                    ? 0.65 + 0.35 * abs(sin(t * 9 + r(6) * 6.28)) : 1
                symbol(&ctx, k, x: x, y: y, size: 14 + r(7) * 10, angle: sin(t * 2 + r(8) * 6) * 0.15,
                       opacity: 0.85 * sin(p * .pi), flipX: dir < 0, scaleY: flap)
            case .confetti:
                let dur = 7 + r(1) * 6
                let p = (t / dur + r(2)).truncatingRemainder(dividingBy: 1)
                let y = -20 + p * (band + 20)
                let x = r(3) * w + sin(t * (0.8 + r(4)) + r(5) * 6.28) * 18
                let fade = min(1, p * 7) * pow(1 - p, 1.2)
                if nSym > 0 && r(8) < 0.15 {
                    symbol(&ctx, Int(r(9) * Double(nSym)) % nSym, x: x, y: y, size: 16 + r(7) * 6,
                           angle: sin(t + r(6) * 6) * 0.4, opacity: 0.85 * fade)
                } else {
                    let palette: [Color] = [Color(hex: 0xFF3EA5), Color(hex: 0xFFC93C), Color(hex: 0x3EC6FF),
                                            Color(hex: 0x7CFF6B), Color(hex: 0xB06BFF), .white]
                    var c = ctx
                    c.opacity = 0.9 * fade
                    c.translateBy(x: x, y: y)
                    c.rotate(by: .radians(t * (r(10) - 0.5) * 6 + r(11) * 6.28))
                    c.scaleBy(x: cos(t * (2 + r(6) * 3) + r(5) * 6.28), y: 1)    // da vueltas en el aire
                    let wd = 4 + r(7) * 3, ht = 7 + r(9) * 5
                    c.fill(Path(roundedRect: CGRect(x: -wd / 2, y: -ht / 2, width: wd, height: ht), cornerRadius: 1),
                           with: .color(palette[Int(r(12) * Double(palette.count)) % palette.count]))
                }
            case .sparkle:
                if r(8) < 0.4 {
                    // destellos de sol que parpadean
                    let x = r(3) * w
                    var y = 30 + r(4) * band * 0.8 - (t * (4 + r(5) * 6)).truncatingRemainder(dividingBy: band * 0.5)
                    if y < 20 { y += band * 0.5 }
                    let tw = pow(max(0, sin(t * (0.9 + r(6) * 1.3) + r(7) * 6.28)), 4)
                    star(&ctx, x: x, y: y, size: 5 + r(9) * 7, color: Color(hex: 0xFFD36B).opacity(0.9 * tw))
                } else {
                    // burbujas que suben
                    let dur = 10 + r(1) * 8
                    let p = (t / dur + r(2)).truncatingRemainder(dividingBy: 1)
                    let y = band - p * band
                    let x = r(3) * w + sin(t * (0.7 + r(4)) + r(5) * 6.28) * 10
                    let d = 4 + r(6) * 9
                    let op = sin(p * .pi) * 0.55
                    let rect = CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(op)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - d * 0.22, y: y - d * 0.3, width: d * 0.18, height: d * 0.18)),
                             with: .color(.white.opacity(op)))
                }
            case .off:
                return
            }
        }
    }

    private func symbol(_ ctx: inout GraphicsContext, _ k: Int, x: Double, y: Double, size: Double,
                        angle: Double, opacity: Double, flipX: Bool = false, scaleY: Double = 1) {
        guard opacity > 0.01, let sym = ctx.resolveSymbol(id: k) else { return }
        var c = ctx
        c.opacity = opacity
        c.translateBy(x: x, y: y)
        c.rotate(by: .radians(angle))
        c.scaleBy(x: (flipX ? -1 : 1) * size / 22, y: scaleY * size / 22)
        c.draw(sym, at: .zero)
    }

    private func star(_ ctx: inout GraphicsContext, x: Double, y: Double, size: Double, color: Color) {
        var p = Path()
        let s = size, k = size * 0.22
        p.move(to: CGPoint(x: x, y: y - s))
        p.addQuadCurve(to: CGPoint(x: x + s, y: y), control: CGPoint(x: x + k, y: y - k))
        p.addQuadCurve(to: CGPoint(x: x, y: y + s), control: CGPoint(x: x + k, y: y + k))
        p.addQuadCurve(to: CGPoint(x: x - s, y: y), control: CGPoint(x: x - k, y: y + k))
        p.addQuadCurve(to: CGPoint(x: x, y: y - s), control: CGPoint(x: x - k, y: y - k))
        ctx.fill(p, with: .color(color))
    }
}
