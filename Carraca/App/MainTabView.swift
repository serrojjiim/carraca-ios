import SwiftUI
import StoreKit

// MARK: - Pestañas

struct MainTabView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.requestReview) private var requestReview
    /// Pestaña en la que se estaba (al volver a abrir la app se sigue ahí).
    @SceneStorage("carraca.tab") private var tab = "live"
    @Environment(\.horizontalSizeClass) private var hsize
    /// Catálogo de películas y de series, compartido por todas las pestañas (y el buscador).
    /// Vive lo que dura la sesión: al entrar con otra cuenta se empieza de cero.
    @StateObject private var movies = CatalogShelf<VodStream>.movies()
    @StateObject private var series = CatalogShelf<SeriesItem>.series()

    /// iPad a pantalla ancha con iPadOS 18 o posterior: barra de pestañas arriba → avisos abajo.
    private var bannersAtBottom: Bool {
        guard #available(iOS 18, *) else { return false }
        return UIDevice.current.userInterfaceIdiom == .pad && hsize == .regular
    }

    private var tabs: [String] {
        var t = ["live"]
        if !session.isM3U { t += ["movies", "series", "continue"] }
        t.append("events")
        return t
    }

    var body: some View {
        TabView(selection: Binding(get: { tabs.contains(tab) ? tab : "live" }, set: { tab = $0 })) {
            LiveView().tabItem { Label("Directo", systemImage: "tv") }.tag("live")
            if !session.isM3U {
                MoviesView().tabItem { Label("Películas", systemImage: "film") }.tag("movies")
                SeriesView().tabItem { Label("Series", systemImage: "rectangle.stack.badge.play") }.tag("series")
                // Mi Carraca: Seguir viendo, Mi lista y Descargas
                LibraryView().tabItem { Label("Mi Carraca", systemImage: "books.vertical") }.tag("continue")
            }
            // Eventos: agenda pública del día, para todos (no depende del servidor de la cuenta)
            EventsView().tabItem { Label("Eventos", systemImage: "sportscourt") }.tag("events")
        }
        // iPad (iPadOS 18+): las pestañas van arriba, flotando; un aviso arriba las tapaba.
        // Ahí los avisos van abajo, como una tarjeta que empuja el contenido (no tapa nada).
        .safeAreaInset(edge: .top, spacing: 0) {
            if !bannersAtBottom {
                VStack(spacing: 0) {
                    ExpiryBanner()
                    SeasonBanner()
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if bannersAtBottom {
                VStack(spacing: 6) {
                    ExpiryBanner().clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    SeasonBanner(edge: .bottom).clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .frame(maxWidth: 640)
                .padding(.horizontal, 16).padding(.bottom, 8)
                .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
            }
        }
        .environmentObject(movies)
        .environmentObject(series)
        // "Recargar listas" (Ajustes): lo ya cargado se vuelve a descargar al momento
        .onChange(of: session.reloadToken) { _ in
            Task { await movies.reloadIfLoaded(session.api) }
            Task { await series.reloadIfLoaded(session.api) }
        }
        // adornos del tema (guirnaldas, emojis, imágenes) colocados desde el panel
        .overlay { OrnamentLayer(tab: tabs.contains(tab) ? tab : "live", tabsOnTop: bannersAtBottom) }
        .onAppear {
            if let t = AppDelegate.pendingTab { tab = t; AppDelegate.pendingTab = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openTab)) { n in
            if let t = n.object as? String { tab = t; AppDelegate.pendingTab = nil }
        }
        .task {
            // Al abrir (no en mitad de un vídeo): unos segundos después de entrar.
            guard ReviewPrompt.shouldAsk else { return }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            ReviewPrompt.markAsked()
            requestReview()
        }
    }
}

/// Aviso arriba cuando la cuenta está a punto de caducar (se puede cerrar; vuelve al día siguiente).
struct ExpiryBanner: View {
    @EnvironmentObject private var session: Session
    @AppStorage("carraca.expiry.hiddenDay") private var hiddenDay = ""

    private var today: String { Date().formatted(.iso8601.year().month().day()) }

    private var days: Int? {
        guard let exp = session.account?.expDate else { return nil }
        let d = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()),
                                                to: Calendar.current.startOfDay(for: exp)).day ?? 99
        return d <= 7 ? d : nil
    }

    var body: some View {
        if let d = days, hiddenDay != today {
            HStack(spacing: 10) {
                Image(systemName: d < 0 ? "exclamationmark.triangle.fill" : "clock.badge.exclamationmark")
                Text(d < 0 ? "Tu cuenta ha caducado." : d == 0 ? "Tu cuenta caduca hoy." :
                        d == 1 ? "Tu cuenta caduca mañana." : "Tu cuenta caduca en \(d) días.")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button { hiddenDay = today } label: { Image(systemName: "xmark").font(.caption.bold()).bannerHitTarget() }
                    .accessibilityLabel("Cerrar aviso")
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(d <= 1 ? Color.red.opacity(0.85) : Color.orange.opacity(0.85))
        }
    }
}
