import SwiftUI
import WebKit

// MARK: - Directo

struct LiveView: View {
    @EnvironmentObject private var session: Session
    @State private var categories: [Category] = []
    @State private var streams: [LiveStream] = []
    @State private var counts: [String: Int] = [:]
    /// Logos de los primeros canales de cada categoría (carátula de la tarjeta).
    @State private var logos: [String: [String]] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var playing: PlayItem?
    /// "Recargar listas" de Ajustes en curso (pantalla de cargando encima).
    @State private var reloading = false
    /// Categorías en tarjetas (por defecto) o en lista; se recuerda en el dispositivo.
    @AppStorage("carraca.live.asList") private var asList = false
    @Environment(\.horizontalSizeClass) private var hsize
    /// iPad: categoría elegida en la columna de la izquierda.
    @State private var selected: Category?

    var body: some View {
        Group {
            if hsize == .regular { splitBody } else { stackBody }
        }
        .task { if streams.isEmpty { await load() } }
        .onChange(of: session.reloadToken) { _ in
            Task {
                reloading = true
                await load(force: true)
                reloading = false
            }
        }
        .overlay { if reloading { ReloadingOverlay() } }
        .fullScreenCover(item: $playing) { PlayerView(item: $0) }
    }

    /// iPad: categorías a la izquierda; canales (con vista previa) a la derecha.
    private var splitBody: some View {
        NavigationSplitView {
            Group {
                if streams.isEmpty && loading {
                    LoadingView()
                } else if streams.isEmpty, let error {
                    ErrorView(message: error) { Task { await load(force: true) } }
                } else {
                    sidebar
                }
            }
            .navigationTitle("Directo")
            .searchable(text: $query, placement: .sidebar, prompt: "Buscar canal")
            .withSettings()
        } detail: {
            NavigationStack {
                if !query.isEmpty {
                    results.navigationTitle("Resultados")
                } else if let cat = selected {
                    ChannelListView(title: title(of: cat), channels: channels(in: cat), makeItem: makeItem)
                        .id(cat.id)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "sidebar.left").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Elige una categoría").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: categories) { cats in
            if selected == nil { selected = cats.first }
        }
    }

    private var sidebar: some View {
        let favs = channels(in: Category.favorites)
        return List(selection: $selected) {
            if !favs.isEmpty {
                CategoryListRow(name: "Favoritos", tag: nil, count: favs.count, logo: favs.first?.icon, symbol: "star.fill")
                    .tag(Category.favorites)
            }
            CategoryListRow(name: "Todos los canales", tag: nil, count: streams.count, logo: nil, symbol: "square.grid.2x2")
                .tag(Category.all)
            ForEach(categories) { c in
                let l = c.name.categoryLabel
                CategoryListRow(name: l.name, tag: l.tag, count: counts[c.id] ?? 0, logo: logos[c.id]?.first)
                    .tag(c)
            }
        }
        .listStyle(.sidebar)
        .refreshable { await load(force: true) }
    }

    private func title(of cat: Category) -> String {
        switch cat.id {
        case Category.all.id: return "Todos los canales"
        case Category.favorites.id: return "Favoritos"
        default: return cat.name.categoryLabel.name
        }
    }

    /// iPhone: tarjetas o lista de categorías y, al tocar, la lista de canales.
    private var stackBody: some View {
        NavigationStack {
            Group {
                if streams.isEmpty && loading {
                    LoadingView()
                } else if streams.isEmpty, let error {
                    ErrorView(message: error) { Task { await load(force: true) } }
                } else if !query.isEmpty {
                    results
                } else if asList {
                    categoryList
                } else {
                    grid
                }
            }
            .navigationTitle("Directo")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { asList.toggle() }
                    } label: {
                        Image(systemName: asList ? "square.grid.2x2" : "list.bullet")
                    }
                    .accessibilityLabel(asList ? "Ver en tarjetas" : "Ver en lista")
                }
            }
            .searchable(text: $query, prompt: "Buscar canal")
            .navigationDestination(for: Category.self) { cat in
                ChannelListView(title: title(of: cat), channels: channels(in: cat), makeItem: makeItem)
            }
            .withSettings()
        }
    }

    private var grid: some View {
        let favs = channels(in: Category.favorites)
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                if !favs.isEmpty {
                    NavigationLink(value: Category.favorites) {
                        CategoryCard(name: "Favoritos", tag: nil, count: favs.count,
                                     logos: favs.compactMap(\.icon).prefix(4).map { $0 }, symbol: "star.fill")
                    }
                    .buttonStyle(.plain)
                }
                NavigationLink(value: Category.all) {
                    CategoryCard(name: "Todos los canales", tag: nil, count: streams.count,
                                 logos: streams.compactMap(\.icon).prefix(4).map { $0 }, symbol: "square.grid.2x2")
                }
                .buttonStyle(.plain)
                ForEach(categories) { c in
                    let l = c.name.categoryLabel
                    NavigationLink(value: c) {
                        CategoryCard(name: l.name, tag: l.tag, count: counts[c.id] ?? 0, logos: logos[c.id] ?? [])
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .refreshable { await load(force: true) }
    }

    /// Misma información que las tarjetas, en filas compactas (caben muchas más categorías).
    private var categoryList: some View {
        let favs = channels(in: Category.favorites)
        return List {
            if !favs.isEmpty {
                NavigationLink(value: Category.favorites) {
                    CategoryListRow(name: "Favoritos", tag: nil, count: favs.count, logo: favs.first?.icon, symbol: "star.fill")
                }
            }
            NavigationLink(value: Category.all) {
                CategoryListRow(name: "Todos los canales", tag: nil, count: streams.count, logo: nil, symbol: "square.grid.2x2")
            }
            ForEach(categories) { c in
                let l = c.name.categoryLabel
                NavigationLink(value: c) {
                    CategoryListRow(name: l.name, tag: l.tag, count: counts[c.id] ?? 0, logo: logos[c.id]?.first)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await load(force: true) }
    }

    private var results: some View {
        let list = Array(streams.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(300))
        return List(list) { s in
            Button { play(s, in: list) } label: { ChannelRow(stream: s) }
                .favoriteActions(s)
        }
        .listStyle(.plain)
    }

    private func channels(in cat: Category) -> [LiveStream] {
        switch cat.id {
        case Category.all.id: return streams
        case Category.favorites.id: return streams.filter { session.isFavorite($0) }
        default: return streams.filter { $0.categoryId == cat.id }
        }
    }

    @MainActor
    private func load(force: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            var cats: [Category]
            let loaded: [LiveStream]
            if session.isM3U {
                // En M3U las categorías salen de group-title, en el orden de la lista.
                loaded = try await session.m3uChannels(force: force)
                var seen = Set<String>()
                cats = []
                for s in loaded where seen.insert(s.categoryId).inserted {
                    cats.append(Category(id: s.categoryId, name: s.categoryId))
                }
            } else {
                guard let api = session.api else { return }
                cats = try await api.liveCategories(force: force)
                loaded = try await api.liveStreams(force: force)
            }
            let all = loaded.filter { !$0.isSeparator }
            var cnt: [String: Int] = [:]
            var lg: [String: [String]] = [:]
            for s in all {
                cnt[s.categoryId, default: 0] += 1
                if let i = s.icon, (lg[s.categoryId]?.count ?? 0) < 4 { lg[s.categoryId, default: []].append(i) }
            }
            counts = cnt
            logos = lg
            categories = cats.filter { (cnt[$0.id] ?? 0) > 0 }
            streams = all
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Qué reproducir para un canal, con la lista para cambiar a anterior / siguiente.
    private func makeItem(_ s: LiveStream, _ list: [LiveStream]) -> PlayItem? {
        let api = session.api
        let urlFor: (LiveStream) -> URL? = { c in c.directURL ?? api?.liveURL(c.id) }
        guard let url = urlFor(s) else { return nil }
        var item = PlayItem(url: url, title: s.name.channelLabel.name, isLive: true, liveStreamId: s.directURL == nil ? s.id : nil)
        let playable = list.filter { urlFor($0) != nil }
        item.channels = playable
        item.channelIndex = playable.firstIndex(of: s) ?? 0
        item.channelURL = { c in urlFor(c)! }
        return item
    }

    private func play(_ s: LiveStream, in list: [LiveStream]) {
        playing = makeItem(s, list)
    }
}

/// Lista de canales de una categoría con vista previa arriba.
/// Un toque: vista previa sin sonido (tras 1 s quieto, para no abrir canales en ráfaga:
/// el proveedor banea la IP). Segundo toque, tocar la previa o el botón: pantalla completa.
struct ChannelListView: View {
    let title: String
    let channels: [LiveStream]
    let makeItem: (LiveStream, [LiveStream]) -> PlayItem?

    @EnvironmentObject private var session: Session
    @Environment(\.scenePhase) private var phase
    @StateObject private var preview = VLCController()
    @State private var query = ""
    @State private var selected: LiveStream?
    @State private var pending: Task<Void, Never>?
    @State private var epg: [EPGEntry] = []
    @State private var playing: PlayItem?

    private static let hm: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        let list = filtered
        VStack(spacing: 0) {
            previewBox(list)
            List(list) { s in
                HStack(spacing: 12) {
                    RemoteImage(url: s.icon, contentMode: .fit)
                        .frame(width: 60, height: 40)
                        .background(Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    let l = s.name.channelLabel
                    Text(l.name).lineLimit(1).foregroundStyle(.primary)
                    if let t = l.tag { TagChip(text: t) }
                    if session.isFavorite(s) {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                    }
                    Spacer()
                    Button { open(s, in: list) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(8)
                    }
                    .buttonStyle(.borderless)
                }
                .contentShape(Rectangle())
                .onTapGesture { tap(s, in: list) }
                .listRowBackground(selected == s ? Color.accentColor.opacity(0.18) : Color.clear)
                .favoriteActions(s)
            }
            .listStyle(.plain)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Buscar en \(title)")
        .onDisappear { stopPreview() }
        .onChange(of: phase) { p in if p != .active { stopPreview() } }
        .fullScreenCover(item: $playing, onDismiss: {
            if let s = selected { schedulePreview(s, delay: 0.6) }
        }) { PlayerView(item: $0) }
    }

    @ViewBuilder
    private func previewBox(_ list: [LiveStream]) -> some View {
        if let s = selected {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color.black
                    VLCVideoView(controller: preview)
                    if preview.failed {
                        Text("No disponible ahora mismo").font(.caption).foregroundStyle(.white.opacity(0.8))
                    } else if preview.buffering || !preview.playing {
                        ProgressView().tint(.white)
                    }
                    // Tocar la previa: pantalla completa.
                    Color.clear.contentShape(Rectangle()).onTapGesture { open(s, in: list) }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(8)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .topTrailing) {
                    Button {
                        stopPreview()
                        selected = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(8)
                }
                .frame(maxWidth: 560)

                Text(s.name.channelLabel.name).font(.headline).lineLimit(1)
                if let now = epg.first {
                    Text("Ahora: \(now.title)\(range(now))").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                if epg.count > 1 {
                    Text("Después: \(epg[1].title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
        } else {
            Label("Toca un canal para verlo aquí. Tócalo otra vez para pantalla completa.", systemImage: "hand.tap")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var filtered: [LiveStream] {
        query.isEmpty ? channels : channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    private func range(_ e: EPGEntry) -> String {
        guard let a = e.start, let b = e.end else { return "" }
        return " · " + Self.hm.string(from: a) + "–" + Self.hm.string(from: b)
    }

    private func tap(_ s: LiveStream, in list: [LiveStream]) {
        if selected == s {
            open(s, in: list)
        } else {
            selected = s
            schedulePreview(s, delay: 1.0)
        }
    }

    /// Una sola previa a la vez: se corta la anterior al momento y la nueva arranca
    /// solo si el canal sigue elegido pasado el retardo.
    private func schedulePreview(_ s: LiveStream, delay: Double) {
        pending?.cancel()
        preview.halt()
        epg = []
        pending = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, selected == s, playing == nil, let item = makeItem(s, [s]) else { return }
            preview.start(url: item.url, startMs: 0, live: true, muted: true)
            guard let id = item.liveStreamId, let api = session.api else { return }
            let list = (try? await api.shortEPG(id)) ?? []
            if selected == s { epg = list }
        }
    }

    private func stopPreview() {
        pending?.cancel()
        pending = nil
        preview.halt()
    }

    private func open(_ s: LiveStream, in list: [LiveStream]) {
        stopPreview()
        selected = s
        playing = makeItem(s, list)
    }
}

extension Category {
    static let home = Category(id: "__inicio__", name: "Inicio")
    static let favorites = Category(id: "__favoritos__", name: "Favoritos")
}

/// Deslizar a la izquierda o mantener pulsado: añadir/quitar de favoritos.
private struct FavoriteActions: ViewModifier {
    @EnvironmentObject private var session: Session
    let stream: LiveStream

    func body(content: Content) -> some View {
        let fav = session.isFavorite(stream)
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { session.toggleFavorite(stream) } label: {
                    Label(fav ? "Quitar" : "Favorito", systemImage: fav ? "star.slash" : "star.fill")
                }
                .tint(.yellow)
            }
            .contextMenu {
                Button { session.toggleFavorite(stream) } label: {
                    Label(fav ? "Quitar de favoritos" : "Añadir a favoritos", systemImage: fav ? "star.slash" : "star")
                }
            }
    }
}

extension View {
    func favoriteActions(_ s: LiveStream) -> some View { modifier(FavoriteActions(stream: s)) }
}

struct ChannelRow: View {
    let stream: LiveStream
    @EnvironmentObject private var session: Session

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: stream.icon, contentMode: .fit)
                .frame(width: 60, height: 40)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            let l = stream.name.channelLabel
            Text(l.name).lineLimit(1).foregroundStyle(.primary)
            if let t = l.tag { TagChip(text: t) }
            if session.isFavorite(stream) {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
            }
            Spacer()
            Image(systemName: "play.circle").foregroundStyle(Color.accentColor)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Películas

struct MoviesView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.horizontalSizeClass) private var hsize
    @State private var categories: [Category] = []
    @State private var movies: [VodStream] = []
    @State private var counts: [String: Int] = [:]
    /// Películas de cada categoría, de la más nueva a la más antigua.
    @State private var byCategory: [String: [VodStream]] = [:]
    @State private var byName: [String: VodStream] = [:]
    @State private var recent: [VodStream] = []
    @State private var top: [VodStream] = []
    @State private var reloading = false
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""

    /// iPad: categoría elegida en el menú lateral (Inicio = filas de carátulas).
    @State private var selected: Category? = Category.home

    var body: some View {
        Group {
            if hsize == .regular { splitBody } else { stackBody }
        }
        .task { if movies.isEmpty { await load() } }
        .onChange(of: session.reloadToken) { _ in
            Task {
                reloading = true
                await load(force: true)
                reloading = false
            }
        }
        .overlay { if reloading { ReloadingOverlay() } }
    }

    /// Lo de dentro: cargando / error / búsqueda / Inicio.
    @ViewBuilder
    private var main: some View {
        if movies.isEmpty && loading {
            LoadingView()
        } else if movies.isEmpty, let error {
            ErrorView(message: error) { Task { await load(force: true) } }
        } else if !query.isEmpty {
            VodGrid(items: Array(movies.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(300)))
        } else {
            home
        }
    }

    /// iPhone: como siempre.
    private var stackBody: some View {
        NavigationStack {
            main
                .navigationTitle("Películas")
                .searchable(text: $query, prompt: "Buscar película")
                .navigationDestination(for: Category.self) { cat in
                    VodGrid(items: byCategory[cat.id] ?? []).navigationTitle(cat.name.categoryLabel.name)
                }
                .navigationDestination(for: VodStream.self) { MovieDetailView(movie: $0) }
                .withSettings()
        }
    }

    /// iPad: menú lateral con las categorías para saltar de una a otra.
    private var splitBody: some View {
        NavigationSplitView {
            VodSidebar(categories: categories, counts: counts, selection: $selected)
                .navigationTitle("Películas")
                .searchable(text: $query, placement: .sidebar, prompt: "Buscar película")
                .withSettings()
        } detail: {
            NavigationStack {
                Group {
                    if query.isEmpty, let cat = selected, cat != Category.home {
                        VodGrid(items: byCategory[cat.id] ?? []).navigationTitle(cat.name.categoryLabel.name)
                    } else {
                        main.navigationTitle(query.isEmpty ? "Inicio" : "Resultados")
                    }
                }
                .navigationDestination(for: Category.self) { cat in
                    VodGrid(items: byCategory[cat.id] ?? []).navigationTitle(cat.name.categoryLabel.name)
                }
                .navigationDestination(for: VodStream.self) { MovieDetailView(movie: $0) }
            }
            .id(selected?.id)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var home: some View {
        let w: CGFloat = hsize == .regular ? 150 : 112
        let cont = continuing
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !cont.isEmpty {
                    PosterRail("Seguir viendo", items: cont, width: w, title: { $0.name.cleanTitle }, image: { $0.icon },
                               progress: { m in session.resumeFor(movie: m.name).map { Double($0.pro) / 100 } })
                }
                if !recent.isEmpty {
                    PosterRail("Recién añadidas", items: recent, width: w, title: { $0.name.cleanTitle }, image: { $0.icon },
                               watched: { session.isWatched(movie: $0.name) })
                }
                if !top.isEmpty {
                    PosterRail("Mejor valoradas", items: top, width: w, title: { $0.name.cleanTitle }, image: { $0.icon },
                               watched: { session.isWatched(movie: $0.name) })
                }
                ForEach(categories) { c in
                    let l = c.name.categoryLabel
                    PosterRail(l.name, tag: l.tag, seeAll: c, count: counts[c.id] ?? 0,
                               items: Array((byCategory[c.id] ?? []).prefix(20)), width: w,
                               title: { $0.name.cleanTitle }, image: { $0.icon },
                               watched: { session.isWatched(movie: $0.name) })
                }
            }
            .padding(.vertical)
        }
        .refreshable { await load(force: true) }
    }

    /// Lo que se dejó a medias (de "Seguir viendo"), como carátulas.
    private var continuing: [VodStream] {
        var seen = Set<Int>()
        return session.resume.filter { $0.type == "movie" }.compactMap { byName[$0.name] }.filter { seen.insert($0.id).inserted }
    }

    @MainActor
    private func load(force: Bool = false) async {
        guard let api = session.api else { return }
        loading = true
        defer { loading = false }
        do {
            let cats = try await api.vodCategories(force: force)
            let all = try await api.vodStreams(force: force)
            let newest = all.sorted { $0.added > $1.added }
            var cnt: [String: Int] = [:]
            var by: [String: [VodStream]] = [:]
            for m in newest {
                cnt[m.categoryId, default: 0] += 1
                by[m.categoryId, default: []].append(m)
            }
            counts = cnt
            byCategory = by
            byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            recent = Array(newest.prefix(20))
            // Mejor nota entre las ~600 más recientes (en el catálogo antiguo hay notas sin sentido).
            top = Array(newest.prefix(600).filter { $0.score >= 6.5 && $0.score < 10 }.sorted { $0.score > $1.score }.prefix(20))
            categories = cats.filter { (cnt[$0.id] ?? 0) > 0 }
            movies = all
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct VodGrid: View {
    let items: [VodStream]
    @EnvironmentObject private var session: Session

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 16) {
                ForEach(items) { v in
                    NavigationLink(value: v) {
                        PosterCell(title: v.name.cleanTitle, image: v.icon,
                                   progress: session.resumeFor(movie: v.name).map { Double($0.pro) / 100 },
                                   watched: session.isWatched(movie: v.name))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

struct MovieDetailView: View {
    let movie: VodStream
    @EnvironmentObject private var session: Session
    @State private var info: VodInfo?
    @State private var playing: PlayItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    Color.clear
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(width: 140)
                        .overlay { RemoteImage(url: movie.icon ?? info?.image) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(movie.name.cleanTitle).font(.title3.bold())
                        if let g = info?.genre, !g.isEmpty { Text(g).font(.subheadline).foregroundStyle(.secondary) }
                        if let r = info?.release, !r.isEmpty { Text(r).font(.subheadline).foregroundStyle(.secondary) }
                        if let d = info?.duration, !d.isEmpty { Label(d, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary) }
                        if let r = movie.rating, let v = Double(r), v > 0 {
                            Label(String(format: "%.1f", v), systemImage: "star.fill").font(.subheadline).foregroundStyle(.yellow)
                        }
                        if session.resumeEnabled {
                            let seen = session.isWatched(movie: movie.name)
                            Button {
                                session.setWatched(type: "movie", name: movie.name, on: !seen)
                            } label: {
                                Label(seen ? "Vista" : "Marcar como vista", systemImage: seen ? "checkmark.circle.fill" : "checkmark.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(seen ? Color.green : Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                }

                if let r = session.resumeFor(movie: movie.name), r.position > 0 {
                    Button { play(from: r.position) } label: {
                        Label("Continuar (\(timeText(r.position)))", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { play(from: 0) } label: {
                        Label("Desde el principio", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                } else {
                    Button { play(from: 0) } label: {
                        Label("Reproducir", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                }

                if let p = info?.plot, !p.isEmpty { Text(p).foregroundStyle(.secondary) }
                if let d = info?.director, !d.isEmpty { Text("Dirección: \(d)").font(.footnote).foregroundStyle(.secondary) }
                if let c = info?.cast, !c.isEmpty { Text("Reparto: \(c)").font(.footnote).foregroundStyle(.secondary) }
            }
            .padding()
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        .task { info = try? await session.api?.vodInfo(movie.id) }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    private func play(from ms: Int) {
        guard let api = session.api else { return }
        playing = PlayItem(url: api.movieURL(movie), title: movie.name.cleanTitle, startMs: ms,
                           resume: ResumeTarget(type: "movie", name: movie.name, itemId: String(movie.id)))
    }
}

func timeText(_ ms: Int) -> String {
    let s = max(0, ms / 1000)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

// MARK: - Series

struct SeriesView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.horizontalSizeClass) private var hsize
    @State private var categories: [Category] = []
    @State private var items: [SeriesItem] = []
    @State private var counts: [String: Int] = [:]
    /// Series de cada categoría, de la actualizada más reciente a la más antigua.
    @State private var byCategory: [String: [SeriesItem]] = [:]
    @State private var byName: [String: SeriesItem] = [:]
    @State private var recent: [SeriesItem] = []
    @State private var reloading = false
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""

    /// iPad: categoría elegida en el menú lateral (Inicio = filas de carátulas).
    @State private var selected: Category? = Category.home

    var body: some View {
        Group {
            if hsize == .regular { splitBody } else { stackBody }
        }
        .task { if items.isEmpty { await load() } }
        .onChange(of: session.reloadToken) { _ in
            Task {
                reloading = true
                await load(force: true)
                reloading = false
            }
        }
        .overlay { if reloading { ReloadingOverlay() } }
    }

    /// Lo de dentro: cargando / error / búsqueda / Inicio.
    @ViewBuilder
    private var main: some View {
        if items.isEmpty && loading {
            LoadingView()
        } else if items.isEmpty, let error {
            ErrorView(message: error) { Task { await load(force: true) } }
        } else if !query.isEmpty {
            SeriesGrid(items: Array(items.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(300)))
        } else {
            home
        }
    }

    /// iPhone: como siempre.
    private var stackBody: some View {
        NavigationStack {
            main
                .navigationTitle("Series")
                .searchable(text: $query, prompt: "Buscar serie")
                .navigationDestination(for: Category.self) { cat in
                    SeriesGrid(items: byCategory[cat.id] ?? []).navigationTitle(cat.name.categoryLabel.name)
                }
                .navigationDestination(for: SeriesItem.self) { SeriesDetailView(series: $0) }
                .withSettings()
        }
    }

    /// iPad: menú lateral con las categorías para saltar de una a otra.
    private var splitBody: some View {
        NavigationSplitView {
            VodSidebar(categories: categories, counts: counts, selection: $selected)
                .navigationTitle("Series")
                .searchable(text: $query, placement: .sidebar, prompt: "Buscar serie")
                .withSettings()
        } detail: {
            NavigationStack {
                Group {
                    if query.isEmpty, let cat = selected, cat != Category.home {
                        SeriesGrid(items: byCategory[cat.id] ?? []).navigationTitle(cat.name.categoryLabel.name)
                    } else {
                        main.navigationTitle(query.isEmpty ? "Inicio" : "Resultados")
                    }
                }
                .navigationDestination(for: Category.self) { cat in
                    SeriesGrid(items: byCategory[cat.id] ?? []).navigationTitle(cat.name.categoryLabel.name)
                }
                .navigationDestination(for: SeriesItem.self) { SeriesDetailView(series: $0) }
            }
            .id(selected?.id)
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var home: some View {
        let w: CGFloat = hsize == .regular ? 150 : 112
        let cont = continuing
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let hero = recent.first(where: { $0.backdrop != nil }) {
                    NavigationLink(value: hero) { HeroBanner(series: hero, height: hsize == .regular ? 320 : 200) }
                        .buttonStyle(.plain)
                        .padding(.horizontal)
                }
                if !cont.isEmpty {
                    PosterRail("Seguir viendo", items: cont, width: w, title: { $0.name.cleanTitle }, image: { $0.cover },
                               progress: { s in session.resumeFor(series: s.name).map { Double($0.pro) / 100 } })
                }
                if !recent.isEmpty {
                    PosterRail("Con capítulos nuevos", items: recent, width: w, title: { $0.name.cleanTitle }, image: { $0.cover })
                }
                ForEach(categories) { c in
                    let l = c.name.categoryLabel
                    PosterRail(l.name, tag: l.tag, seeAll: c, count: counts[c.id] ?? 0,
                               items: Array((byCategory[c.id] ?? []).prefix(20)), width: w,
                               title: { $0.name.cleanTitle }, image: { $0.cover })
                }
            }
            .padding(.vertical)
        }
        .refreshable { await load(force: true) }
    }

    private var continuing: [SeriesItem] {
        var seen = Set<Int>()
        return session.resume.filter { $0.type == "series" }
            .compactMap { byName[$0.name] ?? byName[$0.name.seriesBaseName] }
            .filter { seen.insert($0.id).inserted }
    }

    @MainActor
    private func load(force: Bool = false) async {
        guard let api = session.api else { return }
        loading = true
        defer { loading = false }
        do {
            let cats = try await api.seriesCategories(force: force)
            let all = try await api.series(force: force)
            let newest = all.sorted { $0.updated > $1.updated }
            var cnt: [String: Int] = [:]
            var by: [String: [SeriesItem]] = [:]
            for s in newest {
                cnt[s.categoryId, default: 0] += 1
                by[s.categoryId, default: []].append(s)
            }
            counts = cnt
            byCategory = by
            byName = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            recent = Array(newest.prefix(20))
            categories = cats.filter { (cnt[$0.id] ?? 0) > 0 }
            items = all
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Portada grande de una serie (imagen horizontal + título).
struct HeroBanner: View {
    let series: SeriesItem
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay { RemoteImage(url: series.backdrop) }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(series.name.cleanTitle).font(.title2.bold()).lineLimit(2)
                    if let g = series.genre, !g.isEmpty {
                        Text(g).font(.subheadline).opacity(0.85).lineLimit(1)
                    }
                }
                .foregroundStyle(.white)
                .padding()
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct SeriesGrid: View {
    let items: [SeriesItem]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 16) {
                ForEach(items) { s in
                    NavigationLink(value: s) { PosterCell(title: s.name.cleanTitle, image: s.cover) }
                        .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

struct SeriesDetailView: View {
    let series: SeriesItem
    @EnvironmentObject private var session: Session
    @State private var info: SeriesInfo?
    @State private var season = 0
    @State private var error: String?
    @State private var playing: PlayItem?

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Color.clear
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(width: 110)
                        .overlay { RemoteImage(url: series.cover ?? info?.cover) }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(series.name.cleanTitle).font(.title3.bold())
                        if let g = series.genre, !g.isEmpty { Text(g).font(.subheadline).foregroundStyle(.secondary) }
                        if let p = info?.plot ?? series.plot, !p.isEmpty {
                            Text(p).font(.footnote).foregroundStyle(.secondary).lineLimit(6)
                        }
                    }
                }
                .listRowBackground(Color.clear)

                if let r = session.resumeFor(series: series.name), let ep = episode(season: r.season, number: r.episode) {
                    Button { play(ep, from: r.position, season: r.season) } label: {
                        Label("Continuar T\(r.season) · E\(r.episode) (\(timeText(r.position)))", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                } else if let next = nextEpisode {
                    // Lo siguiente a lo último que se terminó (para no perderse en la serie).
                    Button { play(next.1, from: 0, season: next.0) } label: {
                        Label("Siguiente: T\(next.0) · E\(next.1.number)", systemImage: "forward.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }

            if let info, !info.seasons.isEmpty {
                Section {
                    ForEach(info.episodes[season] ?? []) { ep in
                        let seen = isWatched(ep)
                        Button { play(ep, from: resumeMs(for: ep)) } label: {
                            EpisodeRow(episode: ep, progress: progress(for: ep), watched: seen)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button { toggleWatched(ep) } label: {
                                Label(seen ? "No visto" : "Visto", systemImage: seen ? "eye.slash" : "checkmark")
                            }
                            .tint(seen ? .gray : .green)
                        }
                        .contextMenu {
                            Button { toggleWatched(ep) } label: {
                                Label(seen ? "Marcar como no visto" : "Marcar como visto", systemImage: seen ? "eye.slash" : "checkmark.circle")
                            }
                            Button { markSeasonUpTo(ep) } label: {
                                Label("Marcar vistos hasta aquí", systemImage: "checkmark.circle.badge.questionmark")
                            }
                        }
                    }
                } header: {
                    if info.seasons.count > 1 {
                        Picker("Temporada", selection: $season) {
                            ForEach(info.seasons, id: \.self) { n in
                                Text(seasonDone(n) ? "Temporada \(n) ✓" : "Temporada \(n)").tag(n)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Text("Temporada \(season)")
                    }
                }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .listStyle(.insetGrouped)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    @MainActor
    private func load() async {
        guard info == nil, let api = session.api else { return }
        do {
            let i = try await api.seriesInfo(series.id)
            info = i
            // Temporada inicial: la de lo que está a medias; si no, la del siguiente capítulo por ver.
            let resumeSeason = session.resumeFor(series: series.name)?.season ?? nextEpisode?.0 ?? 0
            season = i.seasons.contains(resumeSeason) ? resumeSeason : (i.seasons.first ?? 0)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func episode(season: Int, number: Int) -> Episode? {
        info?.episodes[season]?.first { $0.number == number }
    }

    private func isResume(_ ep: Episode) -> ResumeItem? {
        guard let r = session.resumeFor(series: series.name), r.season == ep.season || r.season == season,
              r.episode == ep.number else { return nil }
        return r
    }

    private func resumeMs(for ep: Episode) -> Int { isResume(ep)?.position ?? 0 }
    private func progress(for ep: Episode) -> Double? { isResume(ep).map { Double($0.pro) / 100 } }

    /// Temporada real de un capítulo (algunos proveedores no la ponen en el capítulo).
    private func seasonOf(_ ep: Episode) -> Int { ep.season > 0 ? ep.season : season }

    private func isWatched(_ ep: Episode, season s: Int? = nil) -> Bool {
        session.isWatched(series: series.name, season: s ?? seasonOf(ep), episode: ep.number)
    }

    private func toggleWatched(_ ep: Episode) {
        session.setWatched(type: "series", name: series.name, season: seasonOf(ep), episode: ep.number, on: !isWatched(ep))
    }

    /// Marca como vistos todos los capítulos de la temporada hasta este (incluido).
    private func markSeasonUpTo(_ ep: Episode) {
        for e in info?.episodes[season] ?? [] where e.number <= ep.number && !isWatched(e) {
            session.setWatched(type: "series", name: series.name, season: seasonOf(e), episode: e.number, on: true)
        }
    }

    private func seasonDone(_ n: Int) -> Bool {
        guard let eps = info?.episodes[n], !eps.isEmpty else { return false }
        return eps.allSatisfy { isWatched($0, season: n) }
    }

    /// Capítulo siguiente al último terminado (en orden de temporadas).
    private var nextEpisode: (Int, Episode)? {
        guard let info else { return nil }
        let all: [(Int, Episode)] = info.seasons.flatMap { n in (info.episodes[n] ?? []).map { (n, $0) } }
        guard let last = all.lastIndex(where: { isWatched($0.1, season: $0.0) }), last + 1 < all.count else { return nil }
        return all[last + 1]
    }

    private func play(_ ep: Episode, from ms: Int, season forced: Int? = nil) {
        guard let api = session.api else { return }
        let s = forced ?? seasonOf(ep)
        playing = PlayItem(url: api.episodeURL(ep), title: series.name.cleanTitle,
                           subtitle: "T\(s) · E\(ep.number) · \(ep.title.cleanTitle)", startMs: ms,
                           resume: ResumeTarget(type: "series", name: series.name, itemId: ep.id, season: s, episode: ep.number))
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let progress: Double?
    var watched = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if watched {
                    Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                } else {
                    Text("\(episode.number)").font(.headline.monospacedDigit()).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(watched ? "\(episode.number). \(episode.title.cleanTitle)" : episode.title.cleanTitle)
                    .lineLimit(2)
                    .foregroundStyle(watched ? Color.secondary : Color.primary)
                if let d = episode.durationSecs, d > 0 {
                    Text("\(d / 60) min").font(.caption).foregroundStyle(.secondary)
                }
                if let progress { ProgressView(value: progress).tint(.accentColor) }
            }
            Spacer()
            Image(systemName: "play.circle").foregroundStyle(Color.accentColor)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Seguir viendo

struct ContinueView: View {
    @EnvironmentObject private var session: Session
    @State private var allSeries: [SeriesItem] = []
    /// Carátula de cada peli por nombre (de la lista de pelis, que está en caché).
    @State private var movieIcons: [String: String] = [:]
    @State private var playing: PlayItem?

    var body: some View {
        NavigationStack {
            List(session.resume) { item in
                row(item)
            }
            .listStyle(.plain)
            .overlay {
                if session.resume.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Aquí aparecerá lo que dejes a medias.").foregroundStyle(.secondary)
                    }
                }
            }
            .refreshable { await session.refreshResume() }
            .navigationTitle("Seguir viendo")
            .navigationDestination(for: SeriesItem.self) { SeriesDetailView(series: $0) }
            .withSettings()
        }
        .task {
            await session.refreshResume()
            if allSeries.isEmpty { allSeries = (try? await session.api?.series()) ?? [] }
            if movieIcons.isEmpty, let movies = try? await session.api?.vodStreams() {
                var d: [String: String] = [:]
                for m in movies { if let i = m.icon, d[m.name] == nil { d[m.name] = i } }
                movieIcons = d
            }
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    @ViewBuilder
    private func row(_ item: ResumeItem) -> some View {
        let series = item.type == "series" ? findSeries(item.name) : nil
        let image = series?.cover ?? (item.type == "movie" ? movieIcons[item.name] : nil)
        if let s = series {
            NavigationLink(value: s) { ResumeRow(item: item, image: image) }
        } else if !item.url.isEmpty, let url = URL(string: item.url) {
            Button {
                playing = PlayItem(url: url, title: item.name.cleanTitle, startMs: item.position,
                                   resume: ResumeTarget(type: item.type, name: item.name, itemId: item.itemId,
                                                        season: item.season, episode: item.episode))
            } label: { ResumeRow(item: item, image: image) }
        } else {
            ResumeRow(item: item, image: image)
        }
    }

    private func findSeries(_ name: String) -> SeriesItem? {
        let base = name.seriesBaseName
        return allSeries.first { $0.name == name || $0.name == base }
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

// MARK: - Deportes de hoy (misma página del panel que usa Android)

struct SportsView: View {
    @State private var reload = 0

    var body: some View {
        NavigationStack {
            WebView(url: AppConfig.sportsURL, reloadToken: reload)
                .background(Color("LaunchBg"))
                .navigationTitle("Deportes de hoy")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { reload += 1 } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    final class Coordinator { var token = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.load(URLRequest(url: url))
        context.coordinator.token = reloadToken
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        if context.coordinator.token != reloadToken {
            context.coordinator.token = reloadToken
            w.reload()
        }
    }
}
