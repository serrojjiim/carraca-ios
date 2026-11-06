import SwiftUI

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
        VStack(spacing: 0) {
            if decor, let u = theme.upcoming {
                CountdownLabel(moment: u)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(LinearGradient(colors: (theme.current ?? .neutral).colors,
                                               startPoint: .leading, endPoint: .trailing))
                    .transition(.move(edge: edge).combined(with: .opacity))
            }
            greeting
        }
        .animation(.easeInOut(duration: 0.3), value: theme.upcoming?.id)
    }

    @ViewBuilder
    private var greeting: some View {
        if decor, let t = theme.current, !t.message.isEmpty, closed != theme.bannerKey {
            HStack(spacing: 10) {
                Text(t.emoji).font(.title3)
                Text(t.message).font(.subheadline.weight(.semibold)).lineLimit(2)
                Spacer(minLength: 6)
                Button { withAnimation(.easeInOut(duration: 0.25)) { closed = theme.bannerKey } } label: {
                    Image(systemName: "xmark").font(.caption.bold()).bannerHitTarget()
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
            let still = reduceMotion || ProcessInfo.processInfo.isLowPowerModeEnabled
            let stop = theme.paused || phase != .active
            let n = theme.effects >= 2 ? t.particles.count : (t.particles.count + 1) / 2
            ZStack(alignment: .top) {
                if t.id != SeasonTheme.neutral.id {
                    LinearGradient(colors: [t.colors[0].opacity(0.30), t.colors[t.colors.count - 1].opacity(0.10), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 260)
                }
                if t.motion != .off && n > 0 && !still {
                    ParticleField(theme: t, settings: t.particles,
                                  count: t.motion == .fireworks ? max(2, min(12, n / 3)) : n, paused: stop)
                }
                // el momento (fuegos a las 00:00, confeti por el gol…): por toda la pantalla
                if let m = theme.moment, m.effect != .off, !still {
                    ParticleField(theme: t, motion: m.effect, settings: ParticleSettings(count: 28, fullScreen: true),
                                  count: m.effect == .fireworks ? (theme.effects >= 2 ? 7 : 4) : (theme.effects >= 2 ? 28 : 14),
                                  paused: stop)
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
