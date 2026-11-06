import SwiftUI

// MARK: - Buscador global (canales, películas y series a la vez)

struct GlobalSearchView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var chIndex = SearchIndex<LiveStream>()
    /// Películas y series: el catálogo compartido (con su índice ya hecho).
    @EnvironmentObject private var movies: CatalogShelf<VodStream>
    @EnvironmentObject private var series: CatalogShelf<SeriesItem>
    @State private var ch: [LiveStream] = []
    @State private var mv: [VodStream] = []
    @State private var sr: [SeriesItem] = []
    @State private var loading = true
    @State private var playing: PlayItem?

    var body: some View {
        NavigationStack {
            List {
                if query.count < 2 {
                    Text(loading ? "Cargando listas…" : "Escribe al menos 2 letras.")
                        .foregroundStyle(.secondary)
                } else {
                    if ch.isEmpty && mv.isEmpty && sr.isEmpty {
                        Text("Sin resultados.").foregroundStyle(.secondary)
                    }
                    if !ch.isEmpty {
                        Section("Canales") {
                            ForEach(ch) { s in
                                Button { play(s, in: ch) } label: { ChannelRow(stream: s) }
                            }
                        }
                    }
                    if !mv.isEmpty {
                        Section("Películas") {
                            ForEach(mv) { m in
                                NavigationLink(value: m) { searchRow(m.title, m.icon, m.year) }
                            }
                        }
                    }
                    if !sr.isEmpty {
                        Section("Series") {
                            ForEach(sr) { s in
                                NavigationLink(value: s) { searchRow(s.title, s.cover, s.year) }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Buscar")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Canal, película o serie")
            .navigationDestination(for: VodStream.self) { MovieDetailView(movie: $0) }
            .navigationDestination(for: SeriesItem.self) { SeriesDetailView(series: $0) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            }
        }
        .seasonTint()
        .task { await load() }
        .task(id: query) {
            guard query.count >= 2 else { ch = []; mv = []; sr = []; return }
            // espera a que se deje de escribir (no buscar en 20.000 títulos por cada letra)
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            search()
        }
        .fullScreenCover(item: $playing) { PlayerView(item: $0) }
    }

    private func searchRow(_ title: String, _ image: String?, _ year: Int?) -> some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 44, height: 66)
                .overlay { RemoteImage(url: image) }
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).lineLimit(2)
                if let year { Text(String(year)).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    /// Las listas salen de la caché (no se vuelve a descargar nada si ya estaban).
    @MainActor
    private func load() async {
        defer { loading = false }
        if session.isM3U {
            let list = (try? await session.m3uChannels()) ?? []
            chIndex = await makeSearchIndex(list) { $0.name }
            return
        }
        guard let api = session.api else { return }
        let channels = ((try? await api.liveStreams()) ?? []).filter { !$0.isSeparator }
        chIndex = await makeSearchIndex(channels) { $0.name }
        await movies.load(api)
        await series.load(api)
        // si ya había algo escrito mientras cargaba
        if query.count >= 2 { search() }
    }

    private func search() {
        ch = chIndex.search(query, limit: 30)
        mv = movies.index.search(query, limit: 30)
        sr = series.index.search(query, limit: 30)
    }

    private func play(_ s: LiveStream, in list: [LiveStream]) {
        playing = PlayItem.live(s, in: list, api: session.api)
    }
}
