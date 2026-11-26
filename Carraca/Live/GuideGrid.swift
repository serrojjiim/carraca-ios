import SwiftUI

// MARK: - Guía en rejilla por horas (Directo > Guía)

/// Programación de los canales que se ven en la rejilla. Pide a epg_grid.php solo los canales
/// que aparecen en pantalla (las filas son perezosas), en lotes de 80 y con caché de la ventana.
@MainActor
final class GuideGrid: ObservableObject {
    /// 12 horas: el máximo que admite el servidor.
    static let span: TimeInterval = 12 * 3600
    static let batch = 80

    @Published private(set) var programs: [String: [GuideEntry]] = [:]
    /// Descargas en curso (contador: dos a la vez no apagan el indicador antes de tiempo).
    private var inFlight = 0
    @Published private(set) var loading = false
    /// Canales cuya guía no se pudo bajar. Reintentar las pide otra vez.
    @Published private(set) var failedIDs: Set<String> = []
    var failed: Bool { !failedIDs.isEmpty }

    /// Ventana fija: 1 h antes de la hora actual (redondeada a media hora) durante 12 h.
    /// Así from >= ahora-6 h y to-from <= 12 h, como exige el servidor.
    private(set) var start: Date = GuideGrid.windowStart()
    var end: Date { start.addingTimeInterval(Self.span) }

    private var requested: Set<String> = []
    private var queue: Set<String> = []
    private var flushTask: Task<Void, Never>?

    nonisolated static func windowStart(now: Date = Date()) -> Date {
        let base = now.timeIntervalSince1970 - 3600
        return Date(timeIntervalSince1970: floor(base / 1800) * 1800)
    }

    /// Pide la guía de estos canales (solo los que aún no se han pedido en esta ventana).
    func request(_ ids: [String]) {
        let fresh = ids.filter { !requested.contains($0) }
        guard !fresh.isEmpty else { return }
        requested.formUnion(fresh)
        queue.formUnion(fresh)
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            // Solo espera (agrupa las filas que aparecen a la vez al hacer scroll).
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.startFlush()
        }
    }

    /// La descarga va en su propia tarea, sin guardarla: cancelar el debounce no la afecta.
    private func startFlush() {
        Task { [weak self] in await self?.flush() }
    }

    /// Reintento tras un error: vuelve a pedir esos canales.
    func retry(_ ids: [String]) {
        requested.subtract(ids)
        failedIDs.subtract(ids)
        request(ids)
    }

    private func flush() async {
        let ids = Array(queue).sorted()
        queue = []
        guard !ids.isEmpty else { return }
        inFlight += 1
        loading = true
        defer {
            inFlight -= 1
            loading = inFlight > 0
        }
        let from = Int(start.timeIntervalSince1970)
        let to = Int(end.timeIntervalSince1970)
        var offset = 0
        while offset < ids.count {
            let part = Array(ids[offset..<min(offset + Self.batch, ids.count)])
            offset += Self.batch
            if let got = await Self.fetch(ids: part, from: from, to: to) {
                for id in part {
                    programs[id] = got[id] ?? []
                    failedIDs.remove(id)
                }
            } else {
                // Se quita de "pedido" para que vuelva a pedirse al aparecer, y queda marcado.
                for id in part {
                    requested.remove(id)
                    failedIDs.insert(id)
                }
            }
        }
    }

    nonisolated static var gridURL: URL { URL(string: AppConfig.panel + "/epg_grid.php")! }

    /// GET epg_grid.php?ids=a,b&from=&to=  ->  {"t":..,"c":{"id":[[ini,fin,"título"],...]}}
    nonisolated static func fetch(ids: [String], from: Int, to: Int) async -> [String: [GuideEntry]]? {
        guard var comps = URLComponents(url: gridURL, resolvingAgainstBaseURL: false) else { return nil }
        comps.queryItems = [
            URLQueryItem(name: "ids", value: ids.joined(separator: ",")),
            URLQueryItem(name: "from", value: String(from)),
            URLQueryItem(name: "to", value: String(to)),
        ]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        guard let result = try? await URLSession.shared.data(for: req),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return GuideStore.parse(result.0)
    }
}

/// Un programa tocado en la rejilla.
private struct GuidePick: Equatable {
    let channel: LiveStream
    let entry: GuideEntry
}

struct GuideGridView: View {
    let categories: [Category]
    let title: (Category) -> String
    let channels: (Category) -> [LiveStream]
    let makeItem: (LiveStream, [LiveStream]) -> PlayItem?

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var hsize
    @StateObject private var grid = GuideGrid()
    @ObservedObject private var reminders = ProgramReminders.shared
    @State private var category: Category
    @State private var showWithoutGuide = false
    @State private var playing: PlayItem?
    @State private var picked: GuidePick?
    @State private var notice: String?
    @State private var now = Date()
    private let clock = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private let nameWidth: CGFloat = 132
    private let rowH: CGFloat = 60
    private let headerH: CGFloat = 26

    init(categories: [Category], initial: Category,
         title: @escaping (Category) -> String,
         channels: @escaping (Category) -> [LiveStream],
         makeItem: @escaping (LiveStream, [LiveStream]) -> PlayItem?) {
        self.categories = categories
        self.title = title
        self.channels = channels
        self.makeItem = makeItem
        _category = State(initialValue: initial)
    }

    /// Puntos por minuto: más ancho en iPad.
    private var ppm: CGFloat { hsize == .regular ? 4 : 2.6 }
    private var span: CGFloat { CGFloat(GuideGrid.span / 60) * ppm }

    private func x(_ d: Date) -> CGFloat { CGFloat(d.timeIntervalSince(grid.start) / 60) * ppm }

    private var allInCategory: [LiveStream] { channels(category) }
    private var visible: [LiveStream] {
        showWithoutGuide ? allInCategory : allInCategory.filter { $0.epgId != nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !session.guideEnabled {
                    message("La guía solo está disponible con cuentas del servidor Carraca.", symbol: "calendar")
                } else if visible.isEmpty {
                    message(showWithoutGuide ? "No hay canales en esta categoría."
                                             : "Ningún canal de esta categoría tiene guía.", symbol: "tv")
                } else if grid.failed && grid.programs.isEmpty {
                    errorView
                } else {
                    gridScroll
                }
            }
            .navigationTitle(title(category))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(categories, id: \.id) { c in
                            Button(title(c)) { category = c }
                        }
                        Divider()
                        Toggle("Mostrar canales sin guía", isOn: $showWithoutGuide)
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                    .accessibilityLabel("Categoría y opciones")
                }
            }
        }
        .fullScreenCover(item: $playing) { PlayerView(item: $0) }
        .onReceive(clock) { now = $0 }
        .confirmationDialog(picked.map { $0.entry.title } ?? "",
                            isPresented: Binding(get: { picked != nil }, set: { if !$0 { picked = nil } }),
                            titleVisibility: .visible) {
            if let p = picked {
                if p.entry.start <= now && now < p.entry.end {
                    Button("Ver \(p.channel.label.name)") { play(p.channel) }
                } else if reminders.isReminded(channelKey: Session.favoriteID(p.channel), start: p.entry.start) {
                    Button("Quitar aviso") {
                        reminders.remove(channelKey: Session.favoriteID(p.channel), start: p.entry.start)
                    }
                } else if p.entry.start > now {
                    Button("Avisarme antes") { Task { await remind(p) } }
                }
            }
            Button("Cerrar", role: .cancel) {}
        }
        .alert("Guía", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    // MARK: Rejilla

    private var gridScroll: some View {
        ScrollView([.horizontal, .vertical]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(visible, id: \.id) { s in
                        row(s)
                    }
                } header: {
                    timeHeader
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if grid.loading { ProgressView().padding(8) }
        }
        .overlay(alignment: .bottom) {
            if grid.failed {
                HStack(spacing: 10) {
                    Text("Parte de la guía no se ha cargado.")
                        .font(.footnote)
                    Spacer(minLength: 8)
                    Button("Reintentar") { grid.retry(Array(grid.failedIDs)) }
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(12)
            }
        }
    }

    /// Horas cada 30 minutos, en la misma franja horizontal que las filas.
    private var timeHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: nameWidth, height: headerH)
            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: span, height: headerH)
                ForEach(0..<25, id: \.self) { i in
                    Text(grid.start.addingTimeInterval(Double(i) * 1800).formatted(date: .omitted, time: .shortened))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .offset(x: CGFloat(i) * 30 * ppm + 4, y: 6)
                }
            }
            .frame(width: span, height: headerH, alignment: .topLeading)
        }
        .background(Color(.systemBackground))
    }

    private func row(_ s: LiveStream) -> some View {
        HStack(spacing: 0) {
            Button { play(s) } label: {
                VStack(spacing: 3) {
                    ChannelLogo(url: s.icon, width: 44, height: 26)
                    Text(s.label.name).font(.caption2.weight(.semibold)).lineLimit(1)
                }
                .frame(width: nameWidth, height: rowH)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ver \(s.label.name)")

            ZStack(alignment: .topLeading) {
                Color.clear.frame(width: span, height: rowH)
                programsIn(s)
                nowLine
            }
            .frame(width: span, height: rowH, alignment: .topLeading)
            .clipped()
        }
        .frame(height: rowH)
        .overlay(alignment: .bottom) { Divider() }
        .onAppear {
            if let id = s.epgId { grid.request([id]) }
        }
    }

    @ViewBuilder
    private func programsIn(_ s: LiveStream) -> some View {
        if let id = s.epgId {
            if let list = grid.programs[id] {
                if list.isEmpty {
                    Text("Sin programación").font(.caption2).foregroundStyle(.secondary).padding(.leading, 8)
                } else {
                    ForEach(list.filter { $0.end > grid.start && $0.start < grid.end }, id: \.start) { e in
                        block(s, e)
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.04))
                    .frame(width: span - 4, height: rowH - 8)
                    .offset(x: 0, y: 4)
            }
        } else {
            Text("Sin guía").font(.caption2).foregroundStyle(.secondary).padding(.leading, 8)
        }
    }

    /// Un programa: ancho proporcional a su duración dentro de la ventana.
    private func block(_ s: LiveStream, _ e: GuideEntry) -> some View {
        let from = max(e.start, grid.start)
        let to = min(e.end, grid.end)
        let w = max(CGFloat(to.timeIntervalSince(from) / 60) * ppm - 3, 6)
        let live = e.start <= now && now < e.end
        let past = e.end <= now
        let reminded = reminders.isReminded(channelKey: Session.favoriteID(s), start: e.start)
        let when = e.start.formatted(date: .omitted, time: .shortened)
        return Button {
            // En emisión: al canal. Futuro: el menú de "Avisarme".
            if live { play(s) } else { picked = GuidePick(channel: s, entry: e) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if reminded { Image(systemName: "bell.fill").font(.caption2) }
                    Text(e.title).font(.caption.weight(.semibold)).lineLimit(1)
                }
                Text(when).font(.caption2).lineLimit(1)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(width: w, height: rowH - 8, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(live ? Color.accentColor.opacity(0.55) : Color.white.opacity(past ? 0.04 : 0.12))
            )
            .foregroundStyle(past ? Color.secondary : Color.primary)
            .clipped()
        }
        .buttonStyle(.plain)
        .disabled(past)
        .offset(x: x(from), y: 4)
        .accessibilityLabel("\(e.title), \(when)")
    }

    /// Línea de "ahora" (solo si la hora actual cae dentro de la ventana).
    @ViewBuilder
    private var nowLine: some View {
        if now >= grid.start && now < grid.end {
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: rowH)
                .offset(x: x(now), y: 0)
                .allowsHitTesting(false)
        }
    }

    // MARK: Estados y acciones

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text("No se ha podido cargar la guía.").foregroundStyle(.secondary)
            Button("Reintentar") {
                grid.retry(Array(grid.failedIDs))
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func play(_ s: LiveStream) {
        // Una sola conexión: se para la vista previa de la lista (iPad) antes de reproducir.
        NotificationCenter.default.post(name: .stopChannelPreviews, object: nil)
        playing = makeItem(s, allInCategory)
    }

    private func remind(_ p: GuidePick) async {
        let r = ProgramReminder(channelKey: Session.favoriteID(p.channel),
                                channelID: p.channel.id,
                                channelName: p.channel.label.name,
                                title: p.entry.title,
                                start: p.entry.start)
        if let err = await reminders.add(r) { notice = err }
    }
}
