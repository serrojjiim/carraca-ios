import SwiftUI

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
    /// Búsqueda en la categoría: nombres preparados una vez y búsqueda al dejar de escribir.
    @State private var index = SearchIndex<LiveStream>()
    @State private var indexVersion = 0
    @State private var hits: [LiveStream]?

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
                    ChannelLogo(url: s.icon, width: 60, height: 40)
                    ChannelTitle(stream: s)
                    Spacer()
                    Button { open(s, in: list) } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .hitTarget()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Pantalla completa")
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
        .task(id: gridKey(channels)) {
            index = await makeSearchIndex(channels) { $0.name }
            indexVersion += 1
        }
        .task(id: "\(query)|\(indexVersion)") {
            if query.trimmingCharacters(in: .whitespaces).isEmpty { hits = nil; return }
            if let r = await debouncedSearch(query, in: index, limit: 5000) { hits = r }
        }
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
                            .hitTarget()
                    }
                    .accessibilityLabel("Cerrar vista previa")
                    .padding(2)
                }
                .frame(maxWidth: 560)

                Text(s.label.name).font(.headline).lineLimit(1)
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
        query.trimmingCharacters(in: .whitespaces).isEmpty ? channels : (hits ?? channels)
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
            // con guía del panel no hace falta preguntar al proveedor (una petición menos por canal)
            if session.guideEnabled {
                await session.refreshGuide()
                let g = GuideStore.shared.nowNext(s)
                if !g.isEmpty {
                    if selected == s { epg = g.map { EPGEntry(title: $0.title, start: $0.start, end: $0.end) } }
                    return
                }
            }
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

/// Nombre del canal + etiqueta + favorito y, si hay guía, lo que echan ahora.
struct ChannelTitle: View {
    let stream: LiveStream
    @EnvironmentObject private var session: Session
    @ObservedObject private var guide = GuideStore.shared

    var body: some View {
        let l = stream.label
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(l.name).lineLimit(1).foregroundStyle(.primary)
                if let t = l.tag { TagChip(text: t) }
                if session.isFavorite(stream) {
                    Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
                }
            }
            if let now = guide.nowNext(stream).first {
                HStack(spacing: 8) {
                    Text("Ahora: \(now.title)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    ProgramProgress(entry: now).frame(width: 46)
                }
            }
        }
    }
}

/// Barrita con lo que lleva emitido el programa actual.
struct ProgramProgress: View {
    let entry: GuideEntry

    var body: some View {
        let total = entry.end.timeIntervalSince(entry.start)
        let done = Date().timeIntervalSince(entry.start)
        ProgressView(value: total > 0 ? min(1, max(0, done / total)) : 0)
            .tint(.accentColor)
            .scaleEffect(x: 1, y: 0.7)
            .accessibilityLabel("Progreso del programa")
    }
}

struct ChannelRow: View {
    let stream: LiveStream
    @EnvironmentObject private var session: Session

    var body: some View {
        HStack(spacing: 12) {
            ChannelLogo(url: stream.icon, width: 60, height: 40)
            ChannelTitle(stream: stream)
            Spacer()
            Image(systemName: "play.circle").foregroundStyle(Color.accentColor)
        }
        .contentShape(Rectangle())
    }
}
