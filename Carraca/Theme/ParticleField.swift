import SwiftUI

/// Partículas dibujadas en un Canvas (30 fotogramas por segundo, se para con el reproductor abierto).
/// Cada partícula sale de su número (sin estado): mismo dibujo siempre, nada que guardar.
struct ParticleField: View {
    let theme: SeasonTheme
    let motion: SeasonTheme.Motion
    let settings: ParticleSettings
    let count: Int
    let paused: Bool

    init(theme: SeasonTheme, motion: SeasonTheme.Motion? = nil, settings: ParticleSettings = .standard,
         count: Int, paused: Bool) {
        self.theme = theme
        self.motion = motion ?? theme.motion
        self.settings = settings
        self.count = count
        self.paused = paused
    }

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

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize, _ t0: Double) {
        let w = Double(size.width)
        let band = settings.fullScreen ? Double(size.height) + 10 : max(240, Double(size.height) * 0.48)
        let nSym = theme.symbols.count
        let t = t0 * settings.speed
        let z = settings.size
        for i in 0..<count {
            let r = { (k: Double) -> Double in Self.rnd(i, k) }
            switch motion {
            case .snow, .fall:
                let dur = (motion == .snow ? 9 : 12) + r(1) * 9
                let p = (t / dur + r(2)).truncatingRemainder(dividingBy: 1)
                let y = -24 + p * (band + 24)
                let x = r(3) * w + sin(t * (0.35 + r(4) * 0.6) + r(5) * 6.28) * (10 + r(6) * 26)
                let fade = min(1, p * 7) * pow(1 - p, 1.3)
                let useSymbol = nSym > 0 && (motion == .fall || r(8) < 0.2)
                if useSymbol {
                    let s = (motion == .fall ? 15 : 11) + r(7) * 10
                    symbol(&ctx, Int(r(9) * Double(nSym)) % nSym, x: x, y: y, size: s,
                           angle: t * (r(10) - 0.5) * 1.8 + r(11) * 6.28, opacity: 0.8 * fade)
                } else {
                    let d = (2 + r(7) * 3.5) * z
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
                    let wd = (4 + r(7) * 3) * z, ht = (7 + r(9) * 5) * z
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
                    star(&ctx, x: x, y: y, size: (5 + r(9) * 7) * z, color: Color(hex: 0xFFD36B).opacity(0.9 * tw))
                } else {
                    // burbujas que suben
                    let dur = 10 + r(1) * 8
                    let p = (t / dur + r(2)).truncatingRemainder(dividingBy: 1)
                    let y = band - p * band
                    let x = r(3) * w + sin(t * (0.7 + r(4)) + r(5) * 6.28) * 10
                    let d = (4 + r(6) * 9) * z
                    let op = sin(p * .pi) * 0.55
                    let rect = CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)
                    ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(op)), lineWidth: 1)
                    ctx.fill(Path(ellipseIn: CGRect(x: x - d * 0.22, y: y - d * 0.3, width: d * 0.18, height: d * 0.18)),
                             with: .color(.white.opacity(op)))
                }
            case .fireworks:
                firework(&ctx, i, w: w, band: band, t: t, z: z)
            case .off:
                return
            }
        }
    }

    /// Un cohete que sube y estalla en chispas que caen y se apagan; cada vuelta, otro sitio y otro color.
    private func firework(_ ctx: inout GraphicsContext, _ i: Int, w: Double, band: Double, t: Double, z: Double) {
        let dur = 2.8 + Self.rnd(i, 1) * 1.8
        let cyc = t / dur + Self.rnd(i, 2)
        let p = cyc.truncatingRemainder(dividingBy: 1)
        let n = Int(cyc.rounded(.down))
        let rr = { (k: Double) -> Double in Self.rnd(i * 37 + n * 101, k) }
        let palette: [Color] = [Color(hex: 0xFF4D4D), Color(hex: 0xFFC93C), Color(hex: 0x3EDC81), Color(hex: 0x3EA8FF),
                                Color(hex: 0xFF7AE0), Color(hex: 0xFFFFFF), theme.accent]
        let col = palette[Int(rr(5) * Double(palette.count)) % palette.count]
        let cx = (0.1 + rr(3) * 0.8) * w
        let cy = band * (0.12 + rr(4) * 0.36)
        let launch = 0.28
        if p < launch {
            // subida: punto brillante con estela
            let q = p / launch
            let e = 1 - pow(1 - q, 2)
            let y = band - (band - cy) * e
            let x = cx + sin(q * 3 + rr(6) * 6) * 6
            for k in 0..<5 {
                let yy = y + Double(k) * 7
                let a = (1 - Double(k) / 5) * 0.7
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1.5, y: yy - 1.5, width: 3, height: 3)),
                         with: .color(Color(hex: 0xFFE7A8).opacity(a)))
            }
            return
        }
        let q = (p - launch) / (1 - launch)
        let fade = pow(1 - q, 1.5)
        if q < 0.1 {
            let fr = 26 * z * (0.5 + q * 5)
            ctx.fill(Path(ellipseIn: CGRect(x: cx - fr, y: cy - fr, width: fr * 2, height: fr * 2)),
                     with: .color(col.opacity(0.35 * (1 - q / 0.1))))
        }
        let sparks = 22
        let reach = (55 + rr(7) * 55) * z
        let open = 1 - pow(1 - q, 2.6)
        let drop = 38 * z * q * q
        for k in 0..<sparks {
            let ang = Double(k) / Double(sparks) * 2 * .pi + rr(8)
            let sp = reach * (0.75 + Self.rnd(k, rr(9)) * 0.35)
            let x = cx + cos(ang) * sp * open
            let y = cy + sin(ang) * sp * open + drop
            let d = 2.6 * z * (1 - q * 0.5)
            let tw = 0.75 + 0.25 * sin(t * 30 + Double(k))
            ctx.fill(Path(ellipseIn: CGRect(x: x - d / 2, y: y - d / 2, width: d, height: d)),
                     with: .color(col.opacity(fade * tw)))
            // estela corta hacia el centro
            var line = Path()
            line.move(to: CGPoint(x: cx + cos(ang) * sp * open * 0.86, y: cy + sin(ang) * sp * open * 0.86 + drop * 0.9))
            line.addLine(to: CGPoint(x: x, y: y))
            ctx.stroke(line, with: .color(col.opacity(fade * 0.45)), lineWidth: d * 0.5)
        }
    }

    private func symbol(_ ctx: inout GraphicsContext, _ k: Int, x: Double, y: Double, size: Double,
                        angle: Double, opacity: Double, flipX: Bool = false, scaleY: Double = 1) {
        guard opacity > 0.01, let sym = ctx.resolveSymbol(id: k) else { return }
        var c = ctx
        c.opacity = opacity
        c.translateBy(x: x, y: y)
        c.rotate(by: .radians(angle))
        let s = size * settings.size
        c.scaleBy(x: (flipX ? -1 : 1) * s / 22, y: scaleY * s / 22)
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
