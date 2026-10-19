import SwiftUI
import WebKit

// MARK: - Directo

struct LiveView: View {
    @EnvironmentObject private var session: Session
    @State private var categories: [Category] = []
    @State private var streams: [LiveStream] = []
    @State private var counts: [String: Int] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""
    @State private var playing: PlayItem?

    var body: some View {
        NavigationStack {
            Group {
                if streams.isEmpty && loading {
                    LoadingView()
                } else if streams.isEmpty, let error {
                    ErrorView(message: error) { Task { await load(force: true) } }
                } else {
                    list
                }
            }
            .navigationTitle("Directo")
            .navigationDestination(for: Category.self) { cat in
                ChannelListView(title: cat.name, channels: channels(in: cat)) { play($0) }
            }
            .withSettings()
        }
        .task { if streams.isEmpty { await load() } }
        .fullScreenCover(item: $playing) { PlayerView(item: $0) }
    }

    private var list: some View {
        List {
            if query.isEmpty {
                NavigationLink(value: Category.all) { CategoryRow(name: "Todos los canales", count: streams.count) }
                ForEach(categories) { c in
                    NavigationLink(value: c) { CategoryRow(name: c.name, count: counts[c.id] ?? 0) }
                }
            } else {
                ForEach(searchResults) { s in
                    Button { play(s) } label: { ChannelRow(stream: s) }
                }
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Buscar canal")
        .refreshable { await load(force: true) }
    }

    private var searchResults: [LiveStream] {
        Array(streams.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(300))
    }

    private func channels(in cat: Category) -> [LiveStream] {
        cat.id == Category.all.id ? streams : streams.filter { $0.categoryId == cat.id }
    }

    @MainActor
    private func load(force: Bool = false) async {
        loading = true
        defer { loading = false }
        do {
            var cats: [Category]
            let all: [LiveStream]
            if session.isM3U {
                // En M3U las categorías salen de group-title, en el orden de la lista.
                all = try await session.m3uChannels(force: force)
                var seen = Set<String>()
                cats = []
                for s in all where seen.insert(s.categoryId).inserted {
                    cats.append(Category(id: s.categoryId, name: s.categoryId))
                }
            } else {
                guard let api = session.api else { return }
                cats = try await api.liveCategories(force: force)
                all = try await api.liveStreams(force: force)
            }
            var cnt: [String: Int] = [:]
            for s in all { cnt[s.categoryId, default: 0] += 1 }
            counts = cnt
            categories = cats.filter { (cnt[$0.id] ?? 0) > 0 }
            streams = all
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func play(_ s: LiveStream) {
        if let direct = s.directURL {
            playing = PlayItem(url: direct, title: s.name, isLive: true)
        } else if let api = session.api {
            playing = PlayItem(url: api.liveURL(s.id), title: s.name, isLive: true, liveStreamId: s.id)
        }
    }
}

struct ChannelListView: View {
    let title: String
    let channels: [LiveStream]
    let onPlay: (LiveStream) -> Void
    @State private var query = ""

    var body: some View {
        List(filtered) { s in
            Button { onPlay(s) } label: { ChannelRow(stream: s) }
        }
        .listStyle(.plain)
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Buscar en \(title)")
    }

    private var filtered: [LiveStream] {
        query.isEmpty ? channels : channels.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

struct ChannelRow: View {
    let stream: LiveStream

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: stream.icon, contentMode: .fit)
                .frame(width: 60, height: 40)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(stream.name).lineLimit(1).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "play.circle").foregroundStyle(Color.accentColor)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Películas

struct MoviesView: View {
    @EnvironmentObject private var session: Session
    @State private var categories: [Category] = []
    @State private var movies: [VodStream] = []
    @State private var counts: [String: Int] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if movies.isEmpty && loading {
                    LoadingView()
                } else if movies.isEmpty, let error {
                    ErrorView(message: error) { Task { await load(force: true) } }
                } else if !query.isEmpty {
                    VodGrid(items: Array(movies.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(300)))
                } else {
                    List {
                        ForEach(categories) { c in
                            NavigationLink(value: c) { CategoryRow(name: c.name, count: counts[c.id] ?? 0) }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await load(force: true) }
                }
            }
            .navigationTitle("Películas")
            .searchable(text: $query, prompt: "Buscar película")
            .navigationDestination(for: Category.self) { cat in
                VodGrid(items: movies.filter { $0.categoryId == cat.id }).navigationTitle(cat.name)
            }
            .navigationDestination(for: VodStream.self) { MovieDetailView(movie: $0) }
            .withSettings()
        }
        .task { if movies.isEmpty { await load() } }
    }

    @MainActor
    private func load(force: Bool = false) async {
        guard let api = session.api else { return }
        loading = true
        defer { loading = false }
        do {
            let cats = try await api.vodCategories(force: force)
            let all = try await api.vodStreams(force: force)
            var cnt: [String: Int] = [:]
            for m in all { cnt[m.categoryId, default: 0] += 1 }
            counts = cnt
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
                                   progress: session.resumeFor(movie: v.name).map { Double($0.pro) / 100 })
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
    @State private var categories: [Category] = []
    @State private var items: [SeriesItem] = []
    @State private var counts: [String: Int] = [:]
    @State private var loading = false
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty && loading {
                    LoadingView()
                } else if items.isEmpty, let error {
                    ErrorView(message: error) { Task { await load(force: true) } }
                } else if !query.isEmpty {
                    SeriesGrid(items: Array(items.filter { $0.name.localizedCaseInsensitiveContains(query) }.prefix(300)))
                } else {
                    List {
                        ForEach(categories) { c in
                            NavigationLink(value: c) { CategoryRow(name: c.name, count: counts[c.id] ?? 0) }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await load(force: true) }
                }
            }
            .navigationTitle("Series")
            .searchable(text: $query, prompt: "Buscar serie")
            .navigationDestination(for: Category.self) { cat in
                SeriesGrid(items: items.filter { $0.categoryId == cat.id }).navigationTitle(cat.name)
            }
            .navigationDestination(for: SeriesItem.self) { SeriesDetailView(series: $0) }
            .withSettings()
        }
        .task { if items.isEmpty { await load() } }
    }

    @MainActor
    private func load(force: Bool = false) async {
        guard let api = session.api else { return }
        loading = true
        defer { loading = false }
        do {
            let cats = try await api.seriesCategories(force: force)
            let all = try await api.series(force: force)
            var cnt: [String: Int] = [:]
            for s in all { cnt[s.categoryId, default: 0] += 1 }
            counts = cnt
            categories = cats.filter { (cnt[$0.id] ?? 0) > 0 }
            items = all
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
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
                    Button { play(ep, from: r.position) } label: {
                        Label("Continuar T\(r.season) · E\(r.episode) (\(timeText(r.position)))", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }

            if let info, !info.seasons.isEmpty {
                Section {
                    ForEach(info.episodes[season] ?? []) { ep in
                        Button { play(ep, from: resumeMs(for: ep)) } label: { EpisodeRow(episode: ep, progress: progress(for: ep)) }
                    }
                } header: {
                    if info.seasons.count > 1 {
                        Picker("Temporada", selection: $season) {
                            ForEach(info.seasons, id: \.self) { Text("Temporada \($0)").tag($0) }
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
            let resumeSeason = session.resumeFor(series: series.name)?.season ?? 0
            season = i.seasons.contains(resumeSeason) ? resumeSeason : (i.seasons.first ?? 0)
            info = i
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

    private func play(_ ep: Episode, from ms: Int) {
        guard let api = session.api else { return }
        let s = ep.season > 0 ? ep.season : season
        playing = PlayItem(url: api.episodeURL(ep), title: series.name.cleanTitle,
                           subtitle: "T\(s) · E\(ep.number) · \(ep.title.cleanTitle)", startMs: ms,
                           resume: ResumeTarget(type: "series", name: series.name, itemId: ep.id, season: s, episode: ep.number))
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let progress: Double?

    var body: some View {
        HStack(spacing: 12) {
            Text("\(episode.number)")
                .font(.headline.monospacedDigit())
                .frame(width: 34)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title.cleanTitle).lineLimit(2).foregroundStyle(.primary)
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
        }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    @ViewBuilder
    private func row(_ item: ResumeItem) -> some View {
        if item.type == "series", let s = findSeries(item.name) {
            NavigationLink(value: s) { ResumeRow(item: item) }
        } else if !item.url.isEmpty, let url = URL(string: item.url) {
            Button {
                playing = PlayItem(url: url, title: item.name.cleanTitle, startMs: item.position,
                                   resume: ResumeTarget(type: item.type, name: item.name, itemId: item.itemId,
                                                        season: item.season, episode: item.episode))
            } label: { ResumeRow(item: item) }
        } else {
            ResumeRow(item: item)
        }
    }

    private func findSeries(_ name: String) -> SeriesItem? {
        let base = name.seriesBaseName
        return allSeries.first { $0.name == name || $0.name == base }
    }
}

struct ResumeRow: View {
    let item: ResumeItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.type == "series" ? "rectangle.stack.badge.play" : "film")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 36)
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
