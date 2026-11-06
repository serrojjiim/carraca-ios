import SwiftUI

// MARK: - Series

struct SeriesView: View {
    @EnvironmentObject private var session: Session
    @EnvironmentObject private var shelf: CatalogShelf<SeriesItem>
    @Environment(\.horizontalSizeClass) private var hsize
    @ObservedObject private var theme = ThemeStore.shared
    /// "Seguir viendo" con un toque: lo que se reproduce y la ficha pedida desde el menú.
    @State private var playing: PlayItem?
    @State private var detail: SeriesItem?

    var body: some View {
        CatalogScreen(shelf: shelf, title: "Series", searchPrompt: "Buscar serie",
                      jumpTitle: "Categorías de series",
                      grid: { SeriesGrid(items: $0) }, detail: { SeriesDetailView(series: $0) }) { home }
    }

    private var home: some View {
        let w: CGFloat = hsize == .regular ? 150 : 112
        let cont = continuing
        let recent = shelf.recent
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                let heroes = Array(recent.lazy.filter { $0.backdrop != nil }.prefix(6))
                if !heroes.isEmpty {
                    FeaturedCarousel(items: heroes, height: hsize == .regular ? 340 : 210, slide: { s in
                        FeaturedSlide(id: "s\(s.id)", title: s.title, subtitle: s.genre ?? "", backdrop: s.backdrop, poster: s.cover)
                    })
                }
                if !cont.isEmpty {
                    PosterRail("Seguir viendo", items: cont, width: w, title: { $0.title }, image: { $0.cover },
                               progress: { s in session.resumeFor(series: s.name).map { Double($0.pro) / 100 } },
                               play: { s in
                                   guard let r = session.resumeFor(series: s.name) else { detail = s; return }
                                   Task { playing = await resumePlayItem(r, series: s, session: session) }
                               },
                               info: { detail = $0 })
                }
                let mine = session.watchlist.compactMap { k in k.hasPrefix("s") ? Int(k.dropFirst()).flatMap { shelf.byID[$0] } : nil }
                if !mine.isEmpty {
                    PosterRail("Mi lista", items: mine, width: w, title: { $0.title }, image: { $0.cover })
                }
                if let t = theme.current, shelf.seasonal.count >= 3 {
                    PosterRail("\(t.emoji) \(t.railTitle)", seeAll: t.railCategory, count: shelf.seasonal.count,
                               items: Array(shelf.seasonal.prefix(20)), width: w, title: { $0.title }, image: { $0.cover })
                }
                if !recent.isEmpty {
                    PosterRail("Con capítulos nuevos", items: recent, width: w, title: { $0.title }, image: { $0.cover })
                }
                ForEach(shelf.categories) { c in
                    let l = c.label
                    PosterRail(l.name, tag: l.tag, seeAll: c, count: shelf.counts[c.id] ?? 0,
                               items: Array((shelf.byCategory[c.id] ?? []).prefix(20)), width: w,
                               title: { $0.title }, image: { $0.cover })
                }
            }
            .padding(.vertical)
        }
        .navigationDestination(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
            if let s = detail { SeriesDetailView(series: s) }
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    /// Lo que se dejó a medias, como carátulas (una por serie).
    private var continuing: [SeriesItem] {
        var seen = Set<Int>()
        return session.resume.filter { $0.type == "series" }
            .compactMap { shelf.find(named: $0.name) }
            .filter { seen.insert($0.id).inserted }
    }
}
