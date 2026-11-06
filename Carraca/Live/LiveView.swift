import SwiftUI

struct LiveView: View {
    @EnvironmentObject private var session: Session
    @State private var categories: [Category] = []
    @State private var streams: [LiveStream] = []
    @State private var counts: [String: Int] = [:]
    /// Logos de los primeros canales de cada categoría (carátula de la tarjeta).
    @State private var logos: [String: [String]] = [:]
    /// Canales de cada categoría, por id y favoritos: calculados al cargar (no en cada repintado).
    @State private var byCategory: [String: [LiveStream]] = [:]
    @State private var byID: [Int: LiveStream] = [:]
    @State private var favs: [LiveStream] = []
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var index = SearchIndex<LiveStream>()
    @State private var hits: [LiveStream] = []
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
        .task {
            if streams.isEmpty { await load() }
            await session.refreshGuide()
        }
        .onChange(of: session.reloadToken) { _ in
            Task {
                reloading = true
                await load(force: true)
                await session.refreshGuide(force: true)
                reloading = false
            }
        }
        .overlay { if reloading { ReloadingOverlay() } }
        .fullScreenCover(item: $playing) { PlayerView(item: $0) }
        .task(id: query) { if let r = await debouncedSearch(query, in: index, limit: 300) { hits = r } }
        .onChange(of: session.favorites) { _ in favs = streams.filter { session.isFavorite($0) } }
        .onListRefreshed(["live", "live_cat", "m3u"]) { await load() }
    }

    /// iPad: categorías a la izquierda; canales (con vista previa) a la derecha.
    private var splitBody: some View {
        NavigationSplitView {
            Group {
                if streams.isEmpty && loading {
                    SkeletonCards()
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
            lastChannelButton
            if !favs.isEmpty {
                CategoryListRow(name: "Favoritos", tag: nil, count: favs.count, logo: favs.first?.icon, symbol: "star.fill")
                    .tag(Category.favorites)
            }
            CategoryListRow(name: "Todos los canales", tag: nil, count: streams.count, logo: nil, symbol: "square.grid.2x2")
                .tag(Category.all)
            ForEach(categories) { c in
                let l = c.label
                CategoryListRow(name: l.name, tag: l.tag, count: counts[c.id] ?? 0, logo: logos[c.id]?.first)
                    .tag(c)
            }
        }
        .listStyle(.sidebar)
        .refreshable { await load(force: true) }
    }

    /// "Seguir viendo · <último canal>" (abre el canal con su categoría para poder cambiar) y,
    /// debajo, los otros canales vistos hace poco.
    @ViewBuilder
    private var lastChannelButton: some View {
        if query.isEmpty, let id = session.lastChannelID, let ch = byID[id] {
            let more = session.recentChannelIDs.filter { $0 != id }.compactMap { byID[$0] }
            VStack(alignment: .leading, spacing: 10) {
                lastChannelCard(ch)
                if !more.isEmpty { recentStrip(more) }
            }
        }
    }

    /// Canales recientes en fila: logo y nombre; un toque lo abre.
    private func recentStrip(_ list: [LiveStream]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recientes").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(list) { c in
                        Button { play(c, in: byCategory[c.categoryId] ?? [c]) } label: {
                            VStack(spacing: 5) {
                                RemoteImage(url: c.icon, contentMode: .fit)
                                    .padding(5)
                                    .frame(width: 76, height: 48)
                                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                                Text(c.label.name).font(.caption2).lineLimit(1).frame(width: 76)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Ver \(c.label.name)")
                        .favoriteActions(c)
                    }
                }
            }
        }
    }

    private func lastChannelCard(_ ch: LiveStream) -> some View {
        Group {
            Button { play(ch, in: byCategory[ch.categoryId] ?? [ch]) } label: {
                HStack(spacing: 12) {
                    ChannelLogo(url: ch.icon, width: 52, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Seguir viendo").font(.caption).foregroundStyle(.secondary)
                        Text(ch.label.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.accentColor.opacity(0.12)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func title(of cat: Category) -> String {
        switch cat.id {
        case Category.all.id: return "Todos los canales"
        case Category.favorites.id: return "Favoritos"
        default: return cat.label.name
        }
    }

    /// iPhone: tarjetas o lista de categorías y, al tocar, la lista de canales.
    private var stackBody: some View {
        NavigationStack {
            Group {
                if streams.isEmpty && loading {
                    SkeletonCards()
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
            lastChannelButton.padding(.horizontal).padding(.top, 8)
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
                                 logos: Array(streams.lazy.compactMap(\.icon).prefix(4)), symbol: "square.grid.2x2")
                }
                .buttonStyle(.plain)
                ForEach(categories) { c in
                    let l = c.label
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
            lastChannelButton
            if !favs.isEmpty {
                NavigationLink(value: Category.favorites) {
                    CategoryListRow(name: "Favoritos", tag: nil, count: favs.count, logo: favs.first?.icon, symbol: "star.fill")
                }
            }
            NavigationLink(value: Category.all) {
                CategoryListRow(name: "Todos los canales", tag: nil, count: streams.count, logo: nil, symbol: "square.grid.2x2")
            }
            ForEach(categories) { c in
                let l = c.label
                NavigationLink(value: c) {
                    CategoryListRow(name: l.name, tag: l.tag, count: counts[c.id] ?? 0, logo: logos[c.id]?.first)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await load(force: true) }
    }

    private var results: some View {
        let list = hits
        return List(list) { s in
            Button { play(s, in: list) } label: { ChannelRow(stream: s) }
                .favoriteActions(s)
        }
        .listStyle(.plain)
    }

    private func channels(in cat: Category) -> [LiveStream] {
        switch cat.id {
        case Category.all.id: return streams
        case Category.favorites.id: return favs
        default: return byCategory[cat.id] ?? []
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
            var by: [String: [LiveStream]] = [:]
            for s in all {
                cnt[s.categoryId, default: 0] += 1
                by[s.categoryId, default: []].append(s)
                if let i = s.icon, (lg[s.categoryId]?.count ?? 0) < 4 { lg[s.categoryId, default: []].append(i) }
            }
            counts = cnt
            logos = lg
            byCategory = by
            byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            favs = all.filter { session.isFavorite($0) }
            categories = cats.filter { (cnt[$0.id] ?? 0) > 0 }
            streams = all
            index = await makeSearchIndex(all) { $0.name }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Qué reproducir para un canal, con la lista para cambiar a anterior / siguiente.
    private func makeItem(_ s: LiveStream, _ list: [LiveStream]) -> PlayItem? {
        PlayItem.live(s, in: list, api: session.api, all: streams)
    }

    private func play(_ s: LiveStream, in list: [LiveStream]) {
        playing = makeItem(s, list)
    }
}
