import SwiftUI

// MARK: - Mi Carraca (Seguir viendo, Mi lista y Descargas)

/// Todo lo "tuyo" en una pestaña: lo que dejaste a medias, lo guardado para luego y lo descargado.
/// Sale siempre que haya pelis y series (antes las Descargas solo se veían si había "Seguir viendo").
/// Sin internet se abre directamente en Descargas.
struct LibraryView: View {
    enum Part: String, CaseIterable, Identifiable {
        case resume = "Seguir viendo", list = "Mi lista", downloads = "Descargas"
        var id: String { rawValue }
    }

    @EnvironmentObject private var session: Session
    @State private var chosen: Part?
    /// Carátulas y fichas: del catálogo compartido (si Películas o Series ya lo cargaron, no se espera nada).
    @EnvironmentObject private var movies: CatalogShelf<VodStream>
    @EnvironmentObject private var series: CatalogShelf<SeriesItem>
    @State private var playing: PlayItem?
    @State private var detail: SeriesItem?
    /// Preparando la reproducción (fichas de series: hace falta la lista de capítulos).
    @State private var opening: String?

    private var parts: [Part] { session.resumeEnabled ? Part.allCases : [.list, .downloads] }
    private var part: Part { chosen.flatMap { parts.contains($0) ? $0 : nil } ?? parts[0] }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Sección", selection: Binding(get: { part }, set: { chosen = $0 })) {
                    ForEach(parts) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                switch part {
                case .resume: resumeList
                case .list: myList
                case .downloads: DownloadsList()
                }
            }
            .navigationTitle(part.rawValue)
            .navigationDestination(for: SeriesItem.self) { SeriesDetailView(series: $0) }
            .navigationDestination(for: VodStream.self) { MovieDetailView(movie: $0) }
            .navigationDestination(isPresented: Binding(get: { detail != nil }, set: { if !$0 { detail = nil } })) {
                if let s = detail { SeriesDetailView(series: s) }
            }
            .withSettings()
        }
        // sin conexión (y con algo descargado): directamente a Descargas
        .onReceive(Downloads.shared.$online.removeDuplicates()) { on in
            if !on, Downloads.shared.items.contains(where: { $0.state == .done }) { chosen = .downloads }
        }
        .task {
            await session.refreshResume()
            await movies.load(session.api)
            await series.load(session.api)
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    // MARK: Seguir viendo

    private var resumeList: some View {
        List(session.resume) { item in
            row(item)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { session.removeResume(item) } label: {
                        Label("Quitar", systemImage: "trash")
                    }
                }
        }
        .listStyle(.plain)
        .overlay {
            if session.resume.isEmpty {
                emptyState("clock.arrow.circlepath", "Aquí aparecerá lo que dejes a medias.")
            }
        }
        .refreshable { await session.refreshResume() }
    }

    /// Un toque: sigue donde se dejó (capítulo incluido). La ficha de la serie, con el botón (i).
    @ViewBuilder
    private func row(_ item: ResumeItem) -> some View {
        let show = item.type == "series" ? series.find(named: item.name) : nil
        let movie = item.type == "movie" ? movies.byName[item.name] : nil
        let image = show?.cover ?? movie?.icon
        HStack(spacing: 4) {
            Button {
                guard opening == nil else { return }
                opening = item.id
                Task {
                    playing = await resumePlayItem(item, movie: movie, series: show, session: session)
                    opening = nil
                }
            } label: {
                ResumeRow(item: item, image: image)
                    .overlay(alignment: .trailing) {
                        if opening == item.id { ProgressView().padding(.trailing, 6) }
                    }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.primary)
            if let s = show {
                Button { detail = s } label: {
                    Image(systemName: "info.circle").font(.title3).foregroundStyle(Color.accentColor).hitTarget()
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Ver ficha de la serie")
            }
        }
        .contextMenu {
            if let s = show {
                Button { detail = s } label: { Label("Ver ficha", systemImage: "info.circle") }
            }
        }
    }

    // MARK: Mi lista

    private enum Saved: Identifiable {
        case movie(VodStream), series(SeriesItem)
        var id: String {
            switch self {
            case .movie(let m): return Session.listKey(movie: m.id)
            case .series(let s): return Session.listKey(series: s.id)
            }
        }
    }

    private var saved: [Saved] {
        session.watchlist.compactMap { k in
            guard let id = Int(k.dropFirst()) else { return nil }
            if k.hasPrefix("m") { return movies.byID[id].map(Saved.movie) }
            if k.hasPrefix("s") { return series.byID[id].map(Saved.series) }
            return nil
        }
    }

    private var myList: some View {
        let list = saved
        return List {
            ForEach(list) { it in
                Group {
                    switch it {
                    case .movie(let m):
                        NavigationLink(value: m) {
                            savedRow(m.title, m.icon, kind: "Película", year: m.year,
                                     watched: session.isWatched(movie: m.name))
                        }
                    case .series(let s):
                        NavigationLink(value: s) { savedRow(s.title, s.cover, kind: "Serie", year: s.year, watched: false) }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) { session.toggleList(it.id) } label: {
                        Label("Quitar", systemImage: "bookmark.slash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if list.isEmpty {
                if (movies.loading || series.loading) && !session.watchlist.isEmpty {
                    ProgressView()
                } else {
                    emptyState("bookmark", "Guarda pelis y series para luego con \"Mi lista\" en su ficha.")
                }
            }
        }
    }

    private func savedRow(_ title: String, _ image: String?, kind: String, year: Int?, watched: Bool) -> some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 64, height: 96)
                .overlay { RemoteImage(url: image, title: title) }
                .overlay(alignment: .topTrailing) { if watched { WatchedBadge().padding(4) } }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).lineLimit(2).foregroundStyle(.primary)
                Text([kind, year.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func emptyState(_ icon: String, _ text: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct ResumeRow: View {
    let item: ResumeItem
    var image: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            Color.clear
                .frame(width: 64, height: 96)
                .overlay {
                    if image != nil {
                        RemoteImage(url: image)
                    } else {
                        Image(systemName: item.type == "series" ? "rectangle.stack.badge.play" : "film")
                            .font(.title2)
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.name.seriesBaseName.cleanTitle).lineLimit(2).foregroundStyle(.primary)
                Text(item.type == "series" ? "T\(item.season) · E\(item.episode)" : "Película")
                    .font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(item.pro) / 100).tint(.accentColor)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

/// "Seguir viendo" con un toque: qué reproducir para retomar algo empezado. Si se conoce la serie,
/// con la lista de capítulos (para pasar solo al siguiente); si está descargado, desde el iPhone.
@MainActor
func resumePlayItem(_ r: ResumeItem, movie: VodStream? = nil, series: SeriesItem? = nil, session: Session) async -> PlayItem? {
    let target = ResumeTarget(type: r.type, name: r.name, itemId: r.itemId, season: r.season, episode: r.episode)
    if r.type == "series", let s = series, let api = session.api, let info = try? await api.seriesInfo(s.id) {
        let eps = info.episodes[r.season] ?? []
        if let ep = eps.first(where: { $0.id == r.itemId }) ?? eps.first(where: { $0.number == r.episode }) {
            let item = PlayItem.episode(series: s, ep: ep, season: r.season, from: r.position, api: api, info: info)
            return Downloads.shared.preferLocal(item, id: "e\(ep.id)")
        }
    }
    if r.type == "movie", let m = movie, let api = session.api {
        return Downloads.shared.preferLocal(PlayItem.movie(m, from: r.position, api: api), id: "m\(m.id)")
    }
    guard let url = session.playableURL(r.url) else { return nil }
    return PlayItem(url: url, title: r.name.seriesBaseName.cleanTitle,
                    subtitle: r.type == "series" ? "T\(r.season) · E\(r.episode)" : nil,
                    startMs: r.position, resume: target)
}
