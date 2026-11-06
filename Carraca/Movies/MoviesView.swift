import SwiftUI

// MARK: - Películas

struct MoviesView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var shelf: CatalogShelf<VodStream>
    @Environment(\.horizontalSizeClass) private var hsize
    @ObservedObject private var theme = ThemeStore.shared
    /// Mejor valoradas y portada destacada (carrusel): se rehacen con cada carga del catálogo.
    @State private var top: [VodStream] = []
    @State private var featured: [VodStream] = []
    /// "Seguir viendo" con un toque: lo que se reproduce y la ficha pedida desde el menú.
    @State private var playing: PlayItem?
    @State private var detail: VodStream?

    var body: some View {
        CatalogScreen(shelf: shelf, title: "Películas", searchPrompt: "Buscar película",
                      jumpTitle: "Categorías de películas",
                      grid: { VodGrid(items: $0) }, detail: { MovieDetailView(movie: $0) }) { home }
            .task(id: shelf.version) { pickHighlights() }
    }

    private var home: some View {
        let w: CGFloat = hsize == .regular ? 150 : 112
        let cont = continuing
        let api = session.api
        let watched: (VodStream) -> Bool = { session.isWatched(movie: $0.name) }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !featured.isEmpty {
                    FeaturedCarousel(items: featured, height: hsize == .regular ? 340 : 210, slide: { m in
                        FeaturedSlide(id: "m\(m.id)", title: m.title, subtitle: featuredSubtitle(m),
                                      backdrop: nil, poster: m.icon)
                    }, backdrop: { m in (try? await api?.vodInfo(m.id))?.backdrop })
                }
                if !cont.isEmpty {
                    PosterRail("Seguir viendo", items: cont, width: w, title: { $0.title }, image: { $0.icon },
                               progress: { m in session.resumeFor(movie: m.name).map { Double($0.pro) / 100 } },
                               play: { m in
                                   guard let r = session.resumeFor(movie: m.name) else { detail = m; return }
                                   Task { playing = await resumePlayItem(r, movie: m, session: session) }
                               },
                               info: { detail = $0 })
                }
                let mine = session.watchlist.compactMap { k in k.hasPrefix("m") ? Int(k.dropFirst()).flatMap { shelf.byID[$0] } : nil }
                if !mine.isEmpty {
                    PosterRail("Mi lista", items: mine, width: w, title: { $0.title }, image: { $0.icon }, watched: watched)
                }
                if let t = theme.current, shelf.seasonal.count >= 3 {
                    PosterRail("\(t.emoji) \(t.railTitle)", seeAll: t.railCategory, count: shelf.seasonal.count,
                               items: Array(shelf.seasonal.prefix(20)), width: w, title: { $0.title }, image: { $0.icon },
                               watched: watched)
                }
                let recent = shelf.recent
                if !recent.isEmpty {
                    PosterRail("Recién añadidas", items: recent, width: w, title: { $0.title }, image: { $0.icon }, watched: watched)
                }
                if !top.isEmpty {
                    PosterRail("Mejor valoradas", items: top, width: w, title: { $0.title }, image: { $0.icon }, watched: watched)
                }
                ForEach(shelf.categories) { c in
                    let l = c.label
                    PosterRail(l.name, tag: l.tag, seeAll: c, count: shelf.counts[c.id] ?? 0,
                               items: Array((shelf.byCategory[c.id] ?? []).prefix(20)), width: w,
                               title: { $0.title }, image: { $0.icon }, watched: watched)
                }
            }
            .padding(.vertical)
        }
        .navigationDestination(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
            if let m = detail { MovieDetailView(movie: m) }
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    /// Lo que se dejó a medias (de "Seguir viendo"), como carátulas.
    private var continuing: [VodStream] {
        var seen = Set<Int>()
        return session.resume.filter { $0.type == "movie" }.compactMap { shelf.byName[$0.name] }.filter { seen.insert($0.id).inserted }
    }

    private func pickHighlights() {
        let newest = shelf.newest
        // Mejor nota entre las ~600 más recientes (en el catálogo antiguo hay notas sin sentido).
        top = Array(newest.prefix(600).filter { $0.score >= 6.5 && $0.score < 10 }.sorted { $0.score > $1.score }.prefix(20))
        // Portada: estrenos recientes con buena nota (si no hay bastantes, los más nuevos con carátula).
        let good = newest.prefix(120).filter { $0.icon != nil && $0.score >= 6 && $0.score < 10 }
        featured = Array((good.count >= 3 ? Array(good) : newest.filter { $0.icon != nil }).prefix(6))
    }
}
