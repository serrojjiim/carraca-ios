import SwiftUI

/// Hoja "Descargar": versiones de la peli con lo que ocupa cada una (la más ligera, primero).
struct DownloadOptionsView: View {
    let movie: VodStream
    @EnvironmentObject private var session: Session
    @ObservedObject private var downloads = Downloads.shared
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [MovieVersion] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            List {
                if loading {
                    HStack { ProgressView(); Text("Buscando versiones…").foregroundStyle(.secondary) }
                } else if versions.isEmpty {
                    Text("No se ha podido consultar el tamaño. Prueba más tarde.").foregroundStyle(.secondary)
                } else {
                    Section {
                        ForEach(Array(versions.enumerated()), id: \.element.id) { idx, v in
                            Button { start(v) } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(idx == 0 && versions.count > 1 ? "Ligera" : idx == versions.count - 1 && versions.count > 1 ? "Máxima calidad" : "Versión \(idx + 1)")
                                            .font(.headline)
                                        Text(v.movie.name).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    Text(byteText(v.bytes)).font(.subheadline.monospacedDigit())
                                }
                            }
                            .disabled(v.bytes > downloads.freeBytes)
                        }
                    } footer: {
                        Text("Libre en el iPhone: \(byteText(downloads.freeBytes)). Mientras se descarga no podrás ver nada más con esta cuenta (solo admite una conexión); si te pones a ver algo, la descarga se pausa y sigue al terminar.")
                    }
                }
            }
            .navigationTitle("Descargar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } } }
        }
        .seasonTint()
        .task { await load() }
    }

    /// Tamaño de cada versión: una petición pequeña cada vez (de una en una).
    @MainActor
    private func load() async {
        defer { loading = false }
        guard let api = session.api else { return }
        let all = (try? await api.vodStreams()) ?? []
        let key = movie.name.versionKey
        var candidates = all.filter { $0.id != movie.id && !key.isEmpty && $0.name.versionKey == key }
        candidates = [movie] + Array(candidates.prefix(5))
        var found: [MovieVersion] = []
        for m in candidates {
            if let b = await Self.size(of: api.movieURL(m)) { found.append(MovieVersion(movie: m, bytes: b)) }
        }
        versions = found.sorted { $0.bytes < $1.bytes }
    }

    static func size(of url: URL) async -> Int64? {
        var req = URLRequest(url: url)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.setValue("CarracaiOS/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
        guard let res = try? await URLSession.shared.data(for: req),
              let http = res.1 as? HTTPURLResponse else { return nil }
        if let cr = http.value(forHTTPHeaderField: "Content-Range"), let total = cr.split(separator: "/").last {
            return Int64(total)
        }
        return http.expectedContentLength > 1 ? http.expectedContentLength : nil
    }

    private func start(_ v: MovieVersion) {
        guard let api = session.api else { return }
        downloads.enqueue(DownloadItem(id: "m\(movie.id)", kind: "movie", title: movie.title,
                                       image: movie.icon, remote: api.movieURL(v.movie).absoluteString,
                                       ext: v.movie.ext, resumeName: movie.name, itemId: String(movie.id),
                                       total: v.bytes))
        dismiss()
    }
}

// MARK: - Apartado Descargas

struct DownloadsList: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var downloads = Downloads.shared
    @State private var playing: PlayItem?

    var body: some View {
        List {
            if downloads.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle).foregroundStyle(.secondary)
                    Text("Aquí aparecerá lo que descargues para ver sin conexión.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text("Pulsa \"Descargar\" en una película o mantén pulsado un capítulo.")
                        .font(.footnote).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(downloads.items) { it in
                        row(it)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { downloads.remove(it.id) } label: { Label("Borrar", systemImage: "trash") }
                            }
                    }
                } footer: {
                    Text("Ocupan \(byteText(downloads.bytesUsed)) · libre \(byteText(downloads.freeBytes))")
                }
            }
        }
        .listStyle(.insetGrouped)
        .onAppear { downloads.removeWatched(session.isWatched(download:)) }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    @ViewBuilder
    private func row(_ it: DownloadItem) -> some View {
        Button { if it.state == .done { play(it) } } label: {
            HStack(spacing: 14) {
                Color.clear
                    .frame(width: 56, height: 84)
                    .overlay { RemoteImage(url: it.image) }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 5) {
                    Text(it.title).lineLimit(2).foregroundStyle(.primary)
                    if let s = it.subtitle { Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    switch it.state {
                    case .done:
                        Label(byteText(it.total), systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    case .downloading:
                        ProgressView(value: it.progress).tint(.accentColor)
                        Text("\(byteText(it.received)) de \(byteText(it.total))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        if downloads.waitingForWiFi {
                            Label("Esperando Wi-Fi", systemImage: "wifi.exclamationmark").font(.caption2).foregroundStyle(.orange)
                        } else if let r = downloads.rateText(it) {
                            Text(r).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    case .queued:
                        Text(downloads.waitingForWiFi ? "En cola · esperando Wi-Fi" : "En cola").font(.caption).foregroundStyle(.secondary)
                    case .paused:
                        Text("En pausa · \(Int(it.progress * 100)) %").font(.caption).foregroundStyle(.secondary)
                    case .failed:
                        Text("Se ha cortado").font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer()
                switch it.state {
                case .done:
                    Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
                case .downloading, .queued:
                    Button { downloads.pause(it.id) } label: { Image(systemName: "pause.circle").font(.title2).hitTarget() }
                        .buttonStyle(.borderless).accessibilityLabel("Pausar")
                case .paused, .failed:
                    Button { downloads.resume(it.id) } label: { Image(systemName: "arrow.clockwise.circle").font(.title2).hitTarget() }
                        .buttonStyle(.borderless).accessibilityLabel("Seguir descargando")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func play(_ it: DownloadItem) {
        let local = downloads.fileURL(it)
        let pos: Int = {
            if it.kind == "movie" { return session.resumeFor(movie: it.resumeName)?.position ?? 0 }
            if let r = session.resumeFor(series: it.resumeName), r.season == it.season, r.episode == it.episode { return r.position }
            return 0
        }()
        playing = PlayItem(url: local, title: it.title, subtitle: it.subtitle, startMs: pos,
                           resume: ResumeTarget(type: it.kind, name: it.resumeName, itemId: it.itemId,
                                                season: it.season, episode: it.episode))
    }
}

/// Botón / estado de descarga para una peli o un capítulo.
struct DownloadBadge: View {
    let id: String
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        if let it = downloads.item(id) {
            switch it.state {
            case .done: Image(systemName: "arrow.down.circle.fill").foregroundStyle(.green).accessibilityLabel("Descargado")
            case .downloading: ProgressView(value: it.progress).frame(width: 30)
            default: Image(systemName: "arrow.down.circle.dotted").foregroundStyle(.secondary).accessibilityLabel("En cola")
            }
        }
    }
}
