import SwiftUI

// MARK: - Adornos, partículas a medida y momentos (fuegos artificiales, cuenta atrás…)
//
// Todo llega en /tema.json (lo diseña el panel, admin.php > Temas > Adornos / Momentos):
//   "temas": { "navidad": { …, "adornos": [ … ], "particulas": { … }, "pantallas": [ … ] } }
//   "momentos": [ { "desde": "2026-12-31T23:59", "hasta": "2027-01-01T00:30", "efecto": "fuegos", … } ]
// Las versiones anteriores de la app ignoran estas claves.

extension JSONValue {
    var str: String? { if case .string(let s) = self { return s }; return nil }
    var num: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }
    var flag: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return s == "1" || s == "true"
        default: return nil
        }
    }
    var obj: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }
    var arr: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

/// Lo que cae: cantidad, velocidad, tamaño y por dónde.
struct ParticleSettings: Equatable {
    /// En decoración "Normal" (en "Suave", la mitad).
    var count = 24
    var speed = 1.0
    var size = 1.0
    /// Toda la pantalla (si no, solo la parte de arriba y se desvanece hacia la mitad).
    var fullScreen = false

    static let standard = ParticleSettings()

    static func parse(_ o: [String: JSONValue]) -> ParticleSettings {
        var p = ParticleSettings()
        if let n = o["n"]?.num { p.count = Int(min(60, max(0, n))) }
        if let v = o["vel"]?.num { p.speed = min(2.5, max(0.3, v)) }
        if let s = o["tam"]?.num { p.size = min(2.5, max(0.4, s)) }
        p.fullScreen = o["zona"]?.str == "toda"
        return p
    }
}

/// Un adorno colocado en la pantalla: una franja (guirnalda de luces, espumillón, banderines, nieve,
/// carámbanos) arriba o encima de las pestañas, o una pieza (emoji, imagen subida o telaraña) donde se diga.
struct Ornament: Equatable, Identifiable {
    enum Kind: Equatable { case lights, tinsel, bunting, snow, icicles, web, emoji(String), image(String) }
    enum Anim { case none, swing, blink, pulse, float }

    let id: Int
    var kind: Kind
    /// Franjas: abajo (encima de las pestañas) en vez de arriba.
    var bottom = false
    /// Piezas: centro, en fracción del ancho / alto de la pantalla.
    var x = 0.5, y = 0.5
    /// Piezas: lado, en fracción del lado corto de la pantalla.
    var size = 0.15
    var rotation = 0.0
    var anim = Anim.none
    var opacity = 1.0
    var flip = false
    /// Franjas: colores variados (si no, los del tema).
    var multicolor = true

    var isStrip: Bool {
        switch kind {
        case .lights, .tinsel, .bunting, .snow, .icicles: return true
        default: return false
        }
    }

    private static func clamp(_ v: Double?, _ lo: Double, _ hi: Double, _ d: Double) -> Double { min(hi, max(lo, v ?? d)) }

    static func parse(_ list: [JSONValue]) -> [Ornament] {
        var out: [Ornament] = []
        for (i, v) in list.prefix(24).enumerated() {
            guard let o = v.obj, let t = o["t"]?.str else { continue }
            let kind: Kind
            switch t {
            case "luces": kind = .lights
            case "espumillon": kind = .tinsel
            case "banderines": kind = .bunting
            case "nieve": kind = .snow
            case "carambanos": kind = .icicles
            case "telarana": kind = .web
            case "emoji":
                guard let s = o["v"]?.str, !s.isEmpty else { continue }
                kind = .emoji(String(s.prefix(3)))
            case "img":
                // las subidas al panel van como "/temas_img/..." (relativas al panel)
                guard let s = o["v"]?.str, s.hasPrefix("https://") || s.hasPrefix("/") else { continue }
                kind = .image(s.hasPrefix("/") ? AppConfig.panel + s : s)
            default:
                continue
            }
            var x = Ornament(id: i, kind: kind)
            x.bottom = o["pos"]?.str == "abajo"
            x.x = clamp(o["x"]?.num, 0, 1, 0.5)
            x.y = clamp(o["y"]?.num, 0, 1, 0.5)
            x.size = clamp(o["s"]?.num, 0.03, 0.8, 0.15)
            x.rotation = clamp(o["r"]?.num, -180, 180, 0)
            x.opacity = clamp(o["o"]?.num, 0.1, 1, 1)
            x.flip = o["f"]?.flag ?? false
            x.multicolor = o["c"]?.str != "tema"
            switch o["a"]?.str {
            case "balanceo": x.anim = .swing
            case "parpadeo": x.anim = .blink
            case "latido": x.anim = .pulse
            case "flotar": x.anim = .float
            default: break
            }
            out.append(x)
        }
        return out
    }
}

/// Un momento con día y hora (Nochevieja, un partido…): pone un tema, un efecto y un saludo solo
/// ese rato, con cuenta atrás antes si se quiere. Horas de Madrid.
struct ThemeMoment: Equatable, Identifiable {
    let id: String
    let start: Date
    let end: Date
    let effect: SeasonTheme.Motion
    let message: String
    let theme: String?
    /// Segundos antes de empezar en que sale la cuenta atrás (0 = sin cuenta atrás).
    let countdown: TimeInterval
    let countdownText: String
    /// También encima del vídeo (las campanadas se ven en el reproductor).
    let inPlayer: Bool

    private static let fmt: [DateFormatter] = ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm"].map {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Europe/Madrid")
        f.dateFormat = $0
        return f
    }

    private static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        for f in fmt { if let d = f.date(from: s) { return d } }
        return nil
    }

    static func parse(_ list: [JSONValue]) -> [ThemeMoment] {
        var out: [ThemeMoment] = []
        for (i, v) in list.prefix(40).enumerated() {
            guard let o = v.obj, let a = date(o["desde"]?.str), let b = date(o["hasta"]?.str), b > a else { continue }
            let fx: SeasonTheme.Motion
            switch o["efecto"]?.str {
            case "fuegos": fx = .fireworks
            case "confeti": fx = .confetti
            case "nieve": fx = .snow
            case "destellos": fx = .sparkle
            default: fx = .off
            }
            let theme = o["tema"]?.str.flatMap { $0.isEmpty ? nil : $0 }
            out.append(ThemeMoment(id: o["id"]?.str ?? "m\(i)", start: a, end: b, effect: fx,
                                   message: String((o["msg"]?.str ?? "").prefix(120)), theme: theme,
                                   countdown: max(0, min(24 * 60, o["cuenta"]?.num ?? 0)) * 60,
                                   countdownText: String((o["msg_cuenta"]?.str ?? "").prefix(60)),
                                   inPlayer: o["reproductor"]?.flag ?? false))
        }
        return out
    }
}

extension SeasonTheme {
    /// Para un momento sin tema propio (el saludo necesita colores).
    static let neutral = SeasonTheme(id: "momento", name: "Momento", emoji: "✨",
                                     accentUI: UIColor(named: "AccentColor") ?? UIColor(hex: 0x2EB8D1),
                                     colors: [Color(hex: 0x1B3A4B), Color(hex: 0x2A5A78)], symbols: [], motion: .off,
                                     message: "", railTitle: "", keywords: [])
}

// MARK: - Capa de adornos (encima de las pestañas, sin tocar los toques)

struct OrnamentLayer: View {
    /// Pestaña en pantalla ("live", "movies"…): el tema puede elegir en cuáles salen.
    let tab: String
    /// iPad con iPadOS 18: las pestañas van arriba (los adornos "abajo" van al borde).
    let tabsOnTop: Bool
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage(ThemeStore.decorKey) private var decor = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var phase

    private var insets: UIEdgeInsets {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow)?.safeAreaInsets ?? .zero
    }

    var body: some View {
        if decor, theme.effects > 0, let t = theme.current, !t.ornaments.isEmpty,
           t.screens.isEmpty || t.screens.contains(tab) {
            GeometryReader { geo in
                let ins = insets
                let animate = !reduceMotion && !theme.paused && phase == .active
                ZStack(alignment: .topLeading) {
                    ForEach(t.ornaments) { o in
                        if o.isStrip {
                            StripView(o: o, theme: t, width: geo.size.width, animate: animate)
                                .frame(width: geo.size.width, height: 46)
                                .scaleEffect(x: 1, y: o.bottom ? -1 : 1)
                                .position(x: geo.size.width / 2,
                                          y: o.bottom ? geo.size.height - ins.bottom - (tabsOnTop ? 0 : 49) - 23
                                                      : max(23, ins.top - 4))
                                .opacity(o.opacity)
                        } else {
                            PieceView(o: o, theme: t, side: min(geo.size.width, geo.size.height), animate: animate)
                                .position(x: o.x * geo.size.width, y: o.y * geo.size.height)
                        }
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }
}

/// Colores de luces y banderines: variados o los del tema.
private func stripPalette(_ o: Ornament, _ t: SeasonTheme) -> [Color] {
    o.multicolor
        ? [Color(hex: 0xFF4D4D), Color(hex: 0xFFC93C), Color(hex: 0x3EDC81), Color(hex: 0x3EA8FF), Color(hex: 0xFF7AE0)]
        : [t.accent, .white, Color(hex: 0xFFD36B)]
}

/// Número "aleatorio" fijo (0…1) para que cada dibujo salga siempre igual.
private func fixedRandom(_ i: Int, _ k: Double) -> Double {
    let v = sin(Double(i) * 12.9898 + k * 78.233) * 43758.5453
    return v - v.rounded(.down)
}

/// Guirnalda que cuelga a lo ancho (de arriba abajo en una franja de 46 pt).
private struct StripView: View {
    let o: Ornament
    let theme: SeasonTheme
    let width: CGFloat
    let animate: Bool

    var body: some View {
        // las luces y el espumillón brillan (10 fotogramas por segundo basta); el resto, quieto
        let moving = animate && (o.kind == .lights || o.kind == .tinsel)
        TimelineView(.animation(minimumInterval: 0.1, paused: !moving)) { tl in
            Canvas { ctx, size in
                draw(&ctx, size, moving ? tl.date.timeIntervalSinceReferenceDate : 0)
            }
        }
    }

    /// Punto de la curva de una "caída" (bezier cuadrática).
    private func point(_ a: CGPoint, _ c: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint {
        let v = 1 - u
        return CGPoint(x: v * v * a.x + 2 * u * v * c.x + u * u * b.x, y: v * v * a.y + 2 * u * v * c.y + u * u * b.y)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t: Double) {
        let w = Double(size.width)
        let pal = stripPalette(o, theme)
        let swoops = max(2, Int(w / 140))
        let seg = w / Double(swoops)
        let sag = 15.0
        func wire() -> Path {
            var p = Path()
            for i in 0..<swoops {
                let a = CGPoint(x: Double(i) * seg, y: 3), b = CGPoint(x: Double(i + 1) * seg, y: 3)
                p.move(to: a)
                p.addQuadCurve(to: b, control: CGPoint(x: (a.x + b.x) / 2, y: 3 + 2 * sag))
            }
            return p
        }
        switch o.kind {
        case .lights:
            ctx.stroke(wire(), with: .color(Color(hex: 0x2E3B2F)), lineWidth: 1.6)
            var k = 0
            for i in 0..<swoops {
                let a = CGPoint(x: Double(i) * seg, y: 3), b = CGPoint(x: Double(i + 1) * seg, y: 3)
                let c = CGPoint(x: (a.x + b.x) / 2, y: 3 + 2 * sag)
                let n = max(3, Int(seg / 26))
                for j in 1..<n {
                    let p = point(a, c, b, Double(j) / Double(n))
                    let col = pal[k % pal.count]
                    let on = 0.55 + 0.45 * sin(t * 2.4 + Double(k) * 1.7)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 9, y: p.y - 3, width: 18, height: 18)),
                             with: .color(col.opacity(0.28 * on)))
                    ctx.fill(Path(roundedRect: CGRect(x: p.x - 2.5, y: p.y, width: 5, height: 3), cornerRadius: 1),
                             with: .color(Color(hex: 0x3A3A3A)))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y + 2.5, width: 7, height: 10)),
                             with: .color(col.opacity(0.45 + 0.55 * on)))
                    k += 1
                }
            }
        case .tinsel:
            let gold = o.multicolor ? Color(hex: 0xE8B923) : theme.accent
            ctx.stroke(wire(), with: .color(gold.opacity(0.55)), style: StrokeStyle(lineWidth: 9, lineCap: .round))
            ctx.stroke(wire(), with: .color(gold), style: StrokeStyle(lineWidth: 4, lineCap: .round, dash: [2, 3]))
            for i in 0..<swoops {
                let a = CGPoint(x: Double(i) * seg, y: 3), b = CGPoint(x: Double(i + 1) * seg, y: 3)
                let c = CGPoint(x: (a.x + b.x) / 2, y: 3 + 2 * sag)
                for j in 0..<6 {
                    let p = point(a, c, b, (Double(j) + 0.5) / 6)
                    let tw = pow(max(0, sin(t * 3 + Double(i * 6 + j) * 2.1)), 3)
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                             with: .color(.white.opacity(0.3 + 0.7 * tw)))
                }
            }
        case .bunting:
            ctx.stroke(wire(), with: .color(.white.opacity(0.7)), lineWidth: 1)
            var k = 0
            for i in 0..<swoops {
                let a = CGPoint(x: Double(i) * seg, y: 3), b = CGPoint(x: Double(i + 1) * seg, y: 3)
                let c = CGPoint(x: (a.x + b.x) / 2, y: 3 + 2 * sag)
                let n = max(3, Int(seg / 24))
                for j in 0..<n {
                    let p1 = point(a, c, b, Double(j) / Double(n) + 0.02)
                    let p2 = point(a, c, b, Double(j + 1) / Double(n) - 0.02)
                    var tri = Path()
                    tri.move(to: p1)
                    tri.addLine(to: p2)
                    tri.addLine(to: CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 + 15))
                    tri.closeSubpath()
                    ctx.fill(tri, with: .color(pal[k % pal.count]))
                    k += 1
                }
            }
        case .snow:
            var p = Path()
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: w, y: 0))
            var x = w
            var i = 0
            p.addLine(to: CGPoint(x: w, y: 8))
            while x > 0 {
                let step = 18 + fixedRandom(i, 1) * 16
                let h = 5 + fixedRandom(i, 2) * 9
                let nx = max(0, x - step)
                p.addQuadCurve(to: CGPoint(x: nx, y: 8), control: CGPoint(x: (x + nx) / 2, y: 8 + h * 2))
                x = nx
                i += 1
            }
            p.closeSubpath()
            ctx.fill(p, with: .color(Color(hex: 0xBFD9F2).opacity(0.5)))
            ctx.translateBy(x: 0, y: -2)
            ctx.fill(p, with: .color(.white.opacity(0.96)))
        case .icicles:
            ctx.fill(Path(CGRect(x: 0, y: 0, width: w, height: 4)), with: .color(.white.opacity(0.95)))
            var x = 2.0
            var i = 0
            while x < w {
                let wd = 5 + fixedRandom(i, 3) * 6
                let len = 8 + fixedRandom(i, 4) * 26
                var tri = Path()
                tri.move(to: CGPoint(x: x, y: 3))
                tri.addLine(to: CGPoint(x: x + wd, y: 3))
                tri.addLine(to: CGPoint(x: x + wd * 0.55, y: 3 + len))
                tri.closeSubpath()
                ctx.fill(tri, with: .linearGradient(Gradient(colors: [.white.opacity(0.95), Color(hex: 0x9FD3FF).opacity(0.35)]),
                                                    startPoint: CGPoint(x: x, y: 3), endPoint: CGPoint(x: x, y: 3 + len)))
                x += wd + 2 + fixedRandom(i, 5) * 8
                i += 1
            }
        default:
            break
        }
    }
}

/// Pieza suelta: emoji, imagen subida al panel o telaraña.
private struct PieceView: View {
    let o: Ornament
    let theme: SeasonTheme
    let side: CGFloat
    let animate: Bool

    var body: some View {
        let w = max(14, o.size * Double(side))
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !(animate && o.anim != .none))) { tl in
            let t = animate ? tl.date.timeIntervalSinceReferenceDate : 0
            let ph = Double(o.id) * 1.3
            content(w)
                .frame(width: w, height: w)
                .scaleEffect(x: CGFloat(o.flip ? -1 : 1), y: 1)
                .rotationEffect(.degrees(o.rotation + (o.anim == .swing ? sin(t * 1.8 + ph) * 7 : 0)),
                                anchor: o.anim == .swing ? .top : .center)
                .scaleEffect(CGFloat(o.anim == .pulse ? 1 + 0.06 * sin(t * 4 + ph) : 1))
                .opacity(o.opacity * (o.anim == .blink ? 0.6 + 0.4 * sin(t * 3 + ph) : 1))
                .offset(y: CGFloat(o.anim == .float ? sin(t * 1.6 + ph) * 5 : 0))
        }
    }

    @ViewBuilder
    private func content(_ w: Double) -> some View {
        switch o.kind {
        case .emoji(let s):
            Text(s).font(.system(size: w * 0.82)).minimumScaleFactor(0.3).lineLimit(1)
        case .image(let u):
            OrnamentImage(url: u)
        case .web:
            Canvas { ctx, size in
                let r = Double(min(size.width, size.height))
                var p = Path()
                let rays = 6
                for k in 0...rays {
                    let a = Double(k) / Double(rays) * .pi / 2
                    p.move(to: .zero)
                    p.addLine(to: CGPoint(x: cos(a) * r, y: sin(a) * r))
                }
                for ring in 1...5 {
                    let rr = r * Double(ring) / 5.6
                    for k in 0..<rays {
                        let a1 = Double(k) / Double(rays) * .pi / 2, a2 = Double(k + 1) / Double(rays) * .pi / 2
                        let p1 = CGPoint(x: cos(a1) * rr, y: sin(a1) * rr), p2 = CGPoint(x: cos(a2) * rr, y: sin(a2) * rr)
                        let am = (a1 + a2) / 2
                        p.move(to: p1)
                        p.addQuadCurve(to: p2, control: CGPoint(x: cos(am) * rr * 0.86, y: sin(am) * rr * 0.86))
                    }
                }
                ctx.stroke(p, with: .color(.white.opacity(0.6)), lineWidth: 0.9)
            }
        default:
            EmptyView()
        }
    }
}

/// Imagen de un adorno subida al panel (nada mientras carga: sin cuadro gris).
private struct OrnamentImage: View {
    let url: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }
        .task(id: url) {
            guard let u = URL(string: url) else { return }
            if let m = ImageLoader.shared.cached(u, maxPixel: 700) { image = m; return }
            image = await ImageLoader.shared.image(u, maxPixel: 700)
        }
    }
}

// MARK: - Momentos: efecto a pantalla completa, cuenta atrás y encima del vídeo

/// "⏳ Cuenta atrás para 2027 · 04:59" (se actualiza cada segundo).
struct CountdownLabel: View {
    let moment: ThemeMoment

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let left = max(0, Int(moment.start.timeIntervalSince(ctx.date).rounded(.up)))
            HStack(spacing: 8) {
                Text("⏳")
                Text(moment.countdownText.isEmpty ? "Cuenta atrás" : moment.countdownText)
                    .font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 6)
                Text(left >= 3600 ? String(format: "%ld:%02ld:%02ld", left / 3600, left / 60 % 60, left % 60)
                                  : String(format: "%02ld:%02ld", left / 60, left % 60))
                    .font(.headline.monospacedDigit())
            }
        }
    }
}

/// Encima del vídeo (si el momento lo pide): cuenta atrás y, al llegar, fuegos y el saludo un minuto.
struct MomentPlayerLayer: View {
    @ObservedObject private var theme = ThemeStore.shared
    @AppStorage(ThemeStore.decorKey) private var decor = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            if decor, let m = theme.moment, m.inPlayer {
                if m.effect != .off && !reduceMotion {
                    ParticleField(theme: theme.current ?? .neutral, motion: m.effect,
                                  settings: ParticleSettings(count: 28, fullScreen: true),
                                  count: m.effect == .fireworks ? 8 : 28, paused: false)
                        .ignoresSafeArea()
                }
                if !m.message.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        if ctx.date.timeIntervalSince(m.start) < 60 {
                            Text(m.message)
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 22).padding(.vertical, 12)
                                .background(.ultraThinMaterial, in: Capsule())
                                .environment(\.colorScheme, .dark)
                                .padding(.top, 26)
                                .transition(.opacity)
                        }
                    }
                }
            } else if decor, let u = theme.upcoming, u.inPlayer {
                CountdownLabel(moment: u)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 340)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .environment(\.colorScheme, .dark)
                    .padding(.top, 18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
