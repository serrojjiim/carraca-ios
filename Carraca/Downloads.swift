import SwiftUI

/// Algo descargado (o en cola) para ver sin conexión. Solo se ve dentro de la app (apartado Descargas).
struct DownloadItem: Codable, Identifiable, Hashable {
    var id: String              // "m<id peli>" | "e<id capítulo>"
    var kind: String            // "movie" | "series"
    var title: String
    var subtitle: String?
    var image: String?
    var remote: String          // URL de origen (solo en el dispositivo)
    var ext: String
    var resumeName: String      // nombre para "Seguir viendo" / visto
    var itemId: String
    var season = 0
    var episode = 0
    var state = State.queued
    var received: Int64 = 0
    var total: Int64 = 0
    var added = Date()

    enum State: String, Codable { case queued, downloading, paused, done, failed }

    var fileName: String { id + "." + ext }
    var progress: Double { total > 0 ? Double(received) / Double(total) : 0 }
}

/// Gestor de descargas: una a una (la cuenta solo admite 1 conexión), en segundo plano
/// (siguen aunque se cierre la app) y se pausan solas mientras se ve algo por internet.
@MainActor
final class Downloads: NSObject, ObservableObject {
    static let shared = Downloads()

    @Published private(set) var items: [DownloadItem] = []
    /// Pausa automática mientras el reproductor usa la conexión.
    private var pausedForPlayback = false
    private var current: URLSessionDownloadTask?
    private var lastSave = Date.distantPast
    var backgroundCompletion: (() -> Void)?

    nonisolated static let sessionID = "com.carraca.smarter.downloads"

    nonisolated static let dir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Descargas", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        var v = u
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true     // no ocupar la copia de iCloud
        try? v.setResourceValues(rv)
        return u
    }()
    private static var indexFile: URL { dir.appendingPathComponent("descargas.json") }
    private static func resumeFile(_ id: String) -> URL { dir.appendingPathComponent(id + ".resume") }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.allowsCellularAccess = true
        return URLSession(configuration: cfg, delegate: DownloadDelegate.shared, delegateQueue: nil)
    }()

    override init() {
        super.init()
        if let d = try? Data(contentsOf: Self.indexFile),
           let list = try? JSONDecoder().decode([DownloadItem].self, from: d) {
            items = list
        }
        // reengancharse a la tarea que siguiera en marcha si la app se cerró
        session.getAllTasks { tasks in
            Task { @MainActor in
                if let t = tasks.compactMap({ $0 as? URLSessionDownloadTask }).first(where: { $0.state == .running }) {
                    self.current = t
                } else {
                    for i in self.items.indices where self.items[i].state == .downloading { self.items[i].state = .queued }
                    self.startNext()
                }
            }
        }
    }

    // MARK: Consultas

    func item(_ id: String) -> DownloadItem? { items.first { $0.id == id } }
    func fileURL(_ it: DownloadItem) -> URL { Self.dir.appendingPathComponent(it.fileName) }
    var bytesUsed: Int64 { items.filter { $0.state == .done }.reduce(0) { $0 + $1.total } }
    var freeBytes: Int64 {
        (try? Self.dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
    }

    // MARK: Acciones

    func enqueue(_ it: DownloadItem) {
        guard item(it.id) == nil else { return }
        items.insert(it, at: 0)
        save(force: true)
        startNext()
    }

    func remove(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            if items[i].state == .downloading { current?.cancel(); current = nil }
            try? FileManager.default.removeItem(at: fileURL(items[i]))
            try? FileManager.default.removeItem(at: Self.resumeFile(id))
            items.remove(at: i)
            save(force: true)
            startNext()
        }
    }

    func pause(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if items[i].state == .downloading {
            current?.cancel(byProducingResumeData: { data in
                Task { @MainActor in if let data { try? data.write(to: Self.resumeFile(id)) } }
            })
            current = nil
        }
        items[i].state = .paused
        save(force: true)
        startNext()
    }

    func resume(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = .queued
        save(force: true)
        startNext()
    }

    /// El reproductor va a usar la única conexión de la cuenta: se pausa lo que se esté bajando.
    func pauseForPlayback() {
        guard let i = items.firstIndex(where: { $0.state == .downloading }) else { return }
        let id = items[i].id
        current?.cancel(byProducingResumeData: { data in
            Task { @MainActor in if let data { try? data.write(to: Self.resumeFile(id)) } }
        })
        current = nil
        items[i].state = .queued
        pausedForPlayback = true
        save(force: true)
    }

    /// Al cerrar el reproductor, la descarga sigue.
    func resumeAfterPlayback() {
        guard pausedForPlayback else { return }
        pausedForPlayback = false
        startNext()
    }

    private func startNext() {
        guard current == nil, !pausedForPlayback,
              let i = items.firstIndex(where: { $0.state == .queued }) else { return }
        let it = items[i]
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: Self.resumeFile(it.id)) {
            task = session.downloadTask(withResumeData: data)
            try? FileManager.default.removeItem(at: Self.resumeFile(it.id))
        } else if let url = URL(string: it.remote) {
            var req = URLRequest(url: url)
            req.setValue("CarracaiOS/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
            task = session.downloadTask(with: req)
        } else {
            items[i].state = .failed
            return
        }
        task.taskDescription = it.id
        items[i].state = .downloading
        current = task
        task.resume()
        save(force: true)
    }

    // MARK: Desde el delegado

    func progress(_ id: String, received: Int64, total: Int64) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].received = received
        if total > 0 { items[i].total = total }
        if items[i].state != .downloading { items[i].state = .downloading }
        save()
    }

    func finished(_ id: String, ok: Bool, resumeData: Data?) {
        current = nil
        if let i = items.firstIndex(where: { $0.id == id }) {
            if ok {
                items[i].state = .done
                let size = (try? FileManager.default.attributesOfItem(atPath: fileURL(items[i]).path)[.size] as? Int64) ?? nil
                if let size { items[i].total = size; items[i].received = size }
            } else if items[i].state == .downloading {
                if let resumeData { try? resumeData.write(to: Self.resumeFile(id)) }
                items[i].state = .failed
            }
            save(force: true)
        }
        startNext()
    }

    func retry(_ id: String) { resume(id) }

    private func save(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSave) > 2 else { return }
        lastSave = Date()
        if let d = try? JSONEncoder().encode(items) { try? d.write(to: Self.indexFile, options: .atomic) }
    }
}

/// Delegado de la sesión en segundo plano (fuera del hilo principal).
final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    static let shared = DownloadDelegate()

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription else { return }
        Task { @MainActor in Downloads.shared.progress(id, received: totalBytesWritten, total: totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        // el fichero temporal hay que moverlo YA (iOS lo borra al volver de esta función)
        var ok = false
        if code < 400 {
            let ext = (downloadTask.originalRequest?.url?.pathExtension).flatMap { $0.isEmpty ? nil : $0 } ?? "mkv"
            let dest = Downloads.dir.appendingPathComponent(id + "." + ext)
            try? FileManager.default.removeItem(at: dest)
            ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        }
        Task { @MainActor in Downloads.shared.finished(id, ok: ok, resumeData: nil) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let id = task.taskDescription else { return }
        if (error as NSError).code == NSURLErrorCancelled { return }     // pausa o borrado: ya gestionado
        let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in Downloads.shared.finished(id, ok: false, resumeData: data) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            Downloads.shared.backgroundCompletion?()
            Downloads.shared.backgroundCompletion = nil
        }
    }
}

// MARK: - Versiones de una peli (descarga "ligera")

struct MovieVersion: Identifiable {
    let movie: VodStream
    let bytes: Int64
    var id: Int { movie.id }
}

extension String {
    /// Título sin calidad ni adornos, para encontrar la misma peli en varias versiones.
    var versionKey: String {
        var t = cleanTitle.lowercased()
        t = t.replacingOccurrences(of: #"\[[^\]]*\]|\([^)]*\)"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\b(4k|uhd|hdr10?|hdr|dolby|vision|1080p|720p|2160p|fhd|hd|sd|dual|latino|castellano|vose|multi|remux|x265|h265|hevc)\b"#,
                                   with: " ", options: .regularExpression)
        t = t.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }.map(String.init).joined()
        return t.split(separator: " ").joined(separator: " ")
    }
}

func byteText(_ b: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
}

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
        downloads.enqueue(DownloadItem(id: "m\(movie.id)", kind: "movie", title: movie.name.cleanTitle,
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
                    case .queued:
                        Text("En cola").font(.caption).foregroundStyle(.secondary)
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
                    Button { downloads.pause(it.id) } label: { Image(systemName: "pause.circle").font(.title2) }
                        .buttonStyle(.borderless).accessibilityLabel("Pausar")
                case .paused, .failed:
                    Button { downloads.resume(it.id) } label: { Image(systemName: "arrow.clockwise.circle").font(.title2) }
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
