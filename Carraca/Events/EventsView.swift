import SwiftUI

struct EventsView: View {
    @EnvironmentObject private var session: Session
    @Environment(\.scenePhase) private var phase
    @ObservedObject private var reminders = EventReminders.shared
    @State private var events: [SportEvent] = []
    @State private var offline = false
    @State private var loading = false
    @State private var loadedAt = Date.distantPast
    @State private var matcher = ChannelMatcher([])
    @State private var streams: [LiveStream] = []
    @State private var sport = ""
    @State private var now = Date()
    @State private var playing: PlayItem?
    /// Columna de la hora: crece con el tamaño de letra del iPhone.
    @ScaledMetric(relativeTo: .headline) private var timeWidth: CGFloat = 62

    private static let dayTitle: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_ES")
        f.timeZone = SportsFeed.madrid
        f.dateFormat = "EEEE d 'de' MMMM"
        return f
    }()

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Eventos")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Actualizar")
                    }
                }
                .withSettings()
        }
        .task {
            await reminders.refresh()
            if events.isEmpty || Date().timeIntervalSince(loadedAt) > 600 { await reload() }
            await loadChannels()
            // la hora avanza sola: "en juego", "en 20 min"…
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                now = Date()
                if Date().timeIntervalSince(loadedAt) > 1800 { await reload() }
            }
        }
        .onChange(of: phase) { p in
            if p == .active {
                now = Date()
                Task { await reminders.refresh() }
            }
        }
        .onChange(of: session.reloadToken) { _ in Task { await reload(); await loadChannels(force: true) } }
        .onListRefreshed(["live", "m3u"]) { await loadChannels(force: true) }
        .fullScreenCover(item: $playing) { PlayerView(item: $0) }
        .alert("Avisos desactivados", isPresented: $reminders.denied) {
            Button("Abrir Ajustes") {
                if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Para que te avisemos antes de un partido, permite las notificaciones de Carraca en Ajustes.")
        }
    }

    @ViewBuilder
    private var content: some View {
        let visible = events.filter { now < $0.end && (sport.isEmpty || $0.emoji == sport) }
        if events.isEmpty && loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if events.filter({ now < $0.end }).isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sportscourt").font(.system(size: 44)).foregroundStyle(.secondary)
                Text(events.isEmpty ? "No se ha podido cargar la lista" : "No quedan eventos por hoy")
                    .font(.headline)
                Text("La lista se actualiza por la mañana y a media tarde.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button("Actualizar") { Task { await reload() } }.buttonStyle(.bordered)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let live = visible.filter { $0.isLive(now) }
            let next = visible.filter { !$0.isLive(now) }
            List {
                Section {
                    sportChips.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                } header: {
                    HStack {
                        Text("Hoy, " + Self.dayTitle.string(from: events.first?.start ?? now))
                        if offline { Spacer(); Label("Sin conexión", systemImage: "wifi.slash") }
                    }
                }
                if !live.isEmpty {
                    Section("En juego") { ForEach(live) { row($0) } }
                }
                if !next.isEmpty {
                    Section("Próximos") { ForEach(next) { row($0) } }
                }
                if visible.isEmpty {
                    Text("Nada de \(SportsFeed.sportName(sport).lowercased()) lo que queda de día.")
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await reload() }
        }
    }

    /// Filtro por deporte (solo los que hay hoy).
    private var sportChips: some View {
        let sports = events.filter { now < $0.end }.map(\.emoji).filter { !$0.isEmpty }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Todos", selected: sport.isEmpty) { sport = "" }
                ForEach(sports, id: \.self) { e in
                    chip(e + " " + SportsFeed.sportName(e), selected: sport == e) { sport = sport == e ? "" : e }
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }

    private func chip(_ text: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.easeInOut(duration: 0.15)) { action() } }) {
            Text(text)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.08)))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }

    private func row(_ e: SportEvent) -> some View {
        let live = e.isLive(now)
        let found = matcher.matches(e.channels)
        let reminded = reminders.pending.contains(e.notificationID)
        return HStack(alignment: .center, spacing: 12) {
            VStack(spacing: 4) {
                Text(e.time).font(.system(.headline, design: .rounded).monospacedDigit())
                if live {
                    Text("EN JUEGO")
                        .font(.caption2.weight(.heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                        .foregroundStyle(.white)
                } else if let m = minutesTo(e), m <= 60 {
                    Text("en \(m) min").font(.caption2).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: timeWidth)
            VStack(alignment: .leading, spacing: 3) {
                Text((e.emoji.isEmpty ? "" : e.emoji + " ") + e.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                if !e.competition.isEmpty {
                    Text(e.competition.capitalized(with: Locale(identifier: "es_ES")))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if !e.channels.isEmpty {
                    Label(e.channels.joined(separator: " / "), systemImage: "tv")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if !live && reminders.canRemind(e) {
                Button { Task { await reminders.toggle(e) } } label: {
                    Image(systemName: reminded ? "bell.fill" : "bell")
                        .font(.body)
                        .foregroundStyle(reminded ? Color.yellow : Color.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(reminded ? "Quitar aviso" : "Avisarme 10 minutos antes")
            }
            if let best = found.first {
                if found.count > 1 {
                    Menu {
                        ForEach(found) { s in
                            Button { play(s, among: found) } label: {
                                Text(s.label.name + (s.label.tag.map { " · " + $0 } ?? ""))
                            }
                        }
                    } label: {
                        playLabel
                    } primaryAction: {
                        play(best, among: found)
                    }
                    .accessibilityLabel("Ver en \(best.label.name)")
                } else {
                    Button { play(best, among: found) } label: { playLabel }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Ver en \(best.label.name)")
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            ForEach(found) { s in
                Button { play(s, among: found) } label: {
                    Label(s.label.name + (s.label.tag.map { " · " + $0 } ?? ""), systemImage: "play.fill")
                }
            }
        }
    }

    private var playLabel: some View {
        Image(systemName: "play.fill")
            .font(.subheadline.bold())
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.accentColor))
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func minutesTo(_ e: SportEvent) -> Int? {
        let m = Int(ceil(e.start.timeIntervalSince(now) / 60))
        return m > 0 ? m : nil
    }

    @MainActor
    private func reload() async {
        loading = true
        defer { loading = false }
        let r = await SportsFeed.load()
        events = r.events
        offline = r.offline
        now = Date()
        if !r.offline { loadedAt = Date() }
    }

    /// Canales de la cuenta (de la caché: no se descarga nada si ya estaban).
    @MainActor
    private func loadChannels(force: Bool = false) async {
        guard force || matcher.isEmpty else { return }
        let list: [LiveStream]
        if session.isM3U {
            list = (try? await session.m3uChannels()) ?? []
        } else {
            list = (try? await session.api?.liveStreams()) ?? []
        }
        streams = list
        matcher = await Task.detached(priority: .utility) { ChannelMatcher(list) }.value
    }

    /// Abre el canal; con varias señales del mismo evento se puede pasar de una a otra.
    private func play(_ s: LiveStream, among list: [LiveStream]) {
        playing = PlayItem.live(s, in: list, api: session.api, all: streams)
    }
}
