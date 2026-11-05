import SwiftUI
import UserNotifications

// MARK: - Eventos deportivos de hoy (nativo)
//
// La lista la genera el panel (deportes.txt, cron 6:00 y 14:00 UTC), una línea por evento:
//   "21:00  ⚽ Celta - Union Saint-Gilloise · EUROPA LEAGUE · M+ Liga de Campeones"
// Horas de Madrid; el día es el de la última modificación del fichero.

struct SportEvent: Identifiable, Hashable {
    let id: String
    let start: Date
    let time: String
    let emoji: String
    let title: String
    let competition: String
    /// Canales tal como vienen ("M+ Liga de Campeones"); a veces más de uno.
    let channels: [String]

    var end: Date { start.addingTimeInterval(2 * 3600) }
    func isLive(_ now: Date) -> Bool { start <= now && now < end }
    var notificationID: String { "evt|" + id }
}

enum SportsFeed {
    static let madrid = TimeZone(identifier: "Europe/Madrid") ?? .current
    private static let cacheText = "carraca.events.text"
    private static let cacheDay = "carraca.events.day"

    static func parse(_ text: String, day: Date) -> [SportEvent] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = madrid
        let base = cal.dateComponents([.year, .month, .day], from: day)
        var out: [SportEvent] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let m = line.range(of: #"^(\d{1,2}):(\d{2})\s+"#, options: .regularExpression) else { continue }
            let hm = line[m].trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard hm.count == 2, let h = Int(hm[0]), let mi = Int(hm[1]) else { continue }
            var rest = String(line[m.upperBound...])
            // primer "palabra": el emoji del deporte (si lo hay)
            var emoji = ""
            if let first = rest.split(separator: " ", maxSplits: 1).first,
               first.unicodeScalars.contains(where: { $0.properties.isEmojiPresentation || $0.properties.generalCategory == .otherSymbol }) {
                emoji = String(first)
                rest = String(rest.dropFirst(first.count)).trimmingCharacters(in: .whitespaces)
            }
            let parts = rest.components(separatedBy: " · ").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let title = parts.first, !title.isEmpty else { continue }
            let channel = parts.count >= 2 ? parts[parts.count - 1] : ""
            let comp = parts.count >= 3 ? parts[1..<(parts.count - 1)].joined(separator: " · ") : ""
            var dc = base
            dc.hour = h
            dc.minute = mi
            guard let start = cal.date(from: dc) else { continue }
            let chans = channel.components(separatedBy: CharacterSet(charactersIn: "/,"))
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let hhmm = String(format: "%02d:%02d", h, mi)
            let dayKey = String(format: "%04d%02d%02d", base.year ?? 0, base.month ?? 0, base.day ?? 0)
            out.append(SportEvent(id: "\(dayKey)|\(hhmm)|\(title)", start: start, time: hhmm, emoji: emoji,
                                  title: title, competition: comp, channels: chans))
        }
        return out.sorted { $0.start < $1.start }
    }

    /// Descarga la lista (o la última guardada si no hay red).
    static func load() async -> (events: [SportEvent], offline: Bool) {
        var req = URLRequest(url: AppConfig.sportsURL)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.timeoutInterval = 15
        if let res = try? await URLSession.shared.data(for: req),
           let http = res.1 as? HTTPURLResponse, http.statusCode == 200,
           let text = String(data: res.0, encoding: .utf8) {
            var day = Date()
            if let lm = http.value(forHTTPHeaderField: "Last-Modified"),
               let d = httpDate.date(from: lm) { day = d }
            UserDefaults.standard.set(text, forKey: cacheText)
            UserDefaults.standard.set(day.timeIntervalSince1970, forKey: cacheDay)
            return (parse(text, day: day), false)
        }
        if let text = UserDefaults.standard.string(forKey: cacheText) {
            let t = UserDefaults.standard.double(forKey: cacheDay)
            return (parse(text, day: t > 0 ? Date(timeIntervalSince1970: t) : Date()), true)
        }
        return ([], true)
    }

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func sportName(_ emoji: String) -> String {
        switch emoji {
        case "⚽": return "Fútbol"
        case "🏀": return "Baloncesto"
        case "🎾": return "Tenis"
        case "⛳": return "Golf"
        case "🏎", "🏎️", "🏁": return "Motor"
        case "🏍", "🏍️": return "Motos"
        case "🏈": return "NFL"
        case "🏒": return "Hockey"
        case "🏐": return "Voleibol"
        case "🤾", "🤾‍♂️": return "Balonmano"
        case "🚴", "🚴‍♂️": return "Ciclismo"
        case "🏉": return "Rugby"
        case "⚾": return "Béisbol"
        case "🥊": return "Boxeo"
        case "🥋": return "Lucha"
        case "🏆": return "Otros"
        default: return emoji
        }
    }
}

/// Casa el nombre del canal del evento ("M+ Liga de Campeones") con los canales de la lista
/// ("TV: M+ LIGA DE CAMPEONES ᵁᴴᴰ ³⁸⁴⁰ᴾ", "ES: M+ LIGA DE CAMPEONES HD"…).
struct ChannelMatcher {
    private var byKey: [String: [LiveStream]] = [:]

    private static let quality: Set<String> = ["hd", "fhd", "uhd", "sd", "4k", "8k", "raw", "hevc", "h265", "1080p",
                                               "720p", "2160p", "3840p", "1080", "720", "vip", "backup", "multi", "tv"]

    init(_ streams: [LiveStream]) {
        for s in streams where !s.isSeparator {
            let k = Self.key(s.label.name)
            guard !k.isEmpty else { continue }
            byKey[k, default: []].append(s)
        }
    }

    var isEmpty: Bool { byKey.isEmpty }

    /// Nombre → clave: minúsculas sin tildes, "M+" = "Movistar", sin calidades ni signos, todo junto.
    static func key(_ name: String) -> String {
        var s = name.searchKey.lowercased()
        s = s.replacingOccurrences(of: #"(^|[^a-z0-9])m\+"#, with: "$1movistar ", options: .regularExpression)
        s = s.replacingOccurrences(of: "+", with: " ")
        let tokens = s.split { !($0.isLetter || $0.isNumber) }.map(String.init).filter { !quality.contains($0) }
        return tokens.joined()
    }

    /// Mejores señales primero: HD, luego sin etiqueta, 4K, RAW y SD al final.
    private static func rank(_ s: LiveStream) -> Int {
        let t = (s.name + " " + (s.label.tag ?? "")).lowercased()
        if t.contains("uhd") || t.contains("4k") || t.contains("2160") || t.contains("3840") { return 2 }
        if t.contains("raw") || t.contains("hevc") { return 3 }
        if t.range(of: #"\bsd\b"#, options: .regularExpression) != nil { return 4 }
        if t.contains("hd") || t.contains("1080") { return 0 }
        return 1
    }

    func matches(_ channels: [String]) -> [LiveStream] {
        var out: [LiveStream] = []
        var seen = Set<Int>()
        for c in channels {
            let k = Self.key(c)
            guard !k.isEmpty else { continue }
            var alts = [k]
            if k.hasSuffix("1") { alts.append(String(k.dropLast())) } else { alts.append(k + "1") }
            if k == "movistarplus" { alts.append("movistar") }
            if k == "movistar" { alts.append("movistarplus") }
            for a in alts {
                guard let list = byKey[a] else { continue }
                let sorted = list.enumerated().sorted { (Self.rank($0.element), $0.offset) < (Self.rank($1.element), $1.offset) }
                for (_, s) in sorted where seen.insert(s.id).inserted { out.append(s) }
                break
            }
        }
        return out
    }
}

/// Avisos locales "empieza en 10 minutos".
@MainActor
final class EventReminders: ObservableObject {
    static let shared = EventReminders()
    static let lead: TimeInterval = 10 * 60

    @Published private(set) var pending: Set<String> = []
    @Published var denied = false

    func refresh() async {
        let reqs = await UNUserNotificationCenter.current().pendingNotificationRequests()
        pending = Set(reqs.map(\.identifier).filter { $0.hasPrefix("evt|") })
    }

    func canRemind(_ e: SportEvent) -> Bool { e.start.addingTimeInterval(-Self.lead) > Date().addingTimeInterval(5) }

    func toggle(_ e: SportEvent) async {
        let center = UNUserNotificationCenter.current()
        if pending.contains(e.notificationID) {
            center.removePendingNotificationRequests(withIdentifiers: [e.notificationID])
            pending.remove(e.notificationID)
            return
        }
        guard canRemind(e) else { return }
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            let ok = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            if !ok { denied = true; return }
        } else if settings.authorizationStatus == .denied {
            denied = true
            return
        }
        let content = UNMutableNotificationContent()
        content.title = "Empieza en 10 minutos"
        content.body = [e.emoji + " " + e.title, e.channels.joined(separator: " / ")].filter { !$0.isEmpty }.joined(separator: " · ")
        content.sound = .default
        content.userInfo = ["tab": "events"]
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                    from: e.start.addingTimeInterval(-Self.lead))
        let req = UNNotificationRequest(identifier: e.notificationID, content: content,
                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        do {
            try await center.add(req)
            pending.insert(e.notificationID)
        } catch {}
    }
}

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
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red))
                        .foregroundStyle(.white)
                } else if let m = minutesTo(e), m <= 60 {
                    Text("en \(m) min").font(.caption2).foregroundStyle(Color.accentColor)
                }
            }
            .frame(width: 58)
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
                        .frame(width: 36, height: 36)
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
            .frame(width: 36, height: 36)
            .background(Circle().fill(Color.accentColor))
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
        let api = session.api
        let urlFor: (LiveStream) -> URL? = { c in c.directURL ?? api?.liveURL(c.id) }
        guard let url = urlFor(s) else { return }
        var item = PlayItem(url: url, title: s.label.name, isLive: true, liveStreamId: s.directURL == nil ? s.id : nil)
        let playable = list.filter { urlFor($0) != nil }
        item.channels = playable
        item.channelIndex = playable.firstIndex(of: s) ?? 0
        item.channelURL = { c in urlFor(c)! }
        playing = item
    }
}
