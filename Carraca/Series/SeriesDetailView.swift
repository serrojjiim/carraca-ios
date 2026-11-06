import SwiftUI

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
                header
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

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
                                .overlay(alignment: .trailing) { DownloadBadge(id: "e\(ep.id)").padding(.trailing, 34) }
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
                            if Downloads.shared.item("e\(ep.id)") == nil {
                                Button { download(ep) } label: { Label("Descargar", systemImage: "arrow.down.circle") }
                                Button { downloadSeason(from: ep) } label: {
                                    Label("Descargar los que quedan de la temporada", systemImage: "arrow.down.circle.dotted")
                                }
                            } else {
                                Button(role: .destructive) { Downloads.shared.remove("e\(ep.id)") } label: {
                                    Label("Borrar descarga", systemImage: "trash")
                                }
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
        .scrollContentBackground(.hidden)
        .background(Color("LaunchBg").ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    /// Fondo grande (imagen horizontal o carátula desenfocada) con la carátula y los datos encima.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: 210)
                .overlay {
                    if let b = series.backdrop ?? info?.backdrop {
                        RemoteImage(url: b, maxPixel: 1400)
                    } else {
                        RemoteImage(url: series.cover ?? info?.cover).blur(radius: 28).opacity(0.7)
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, Color("LaunchBg").opacity(0.6), Color("LaunchBg")],
                                   startPoint: .top, endPoint: .bottom)
                }
                .clipped()
            HStack(alignment: .top, spacing: 16) {
                Color.clear
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .frame(width: 120)
                    .overlay { RemoteImage(url: series.cover ?? info?.cover) }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text(series.title).font(.title3.bold())
                    if let g = series.genre, !g.isEmpty { Text(g).font(.subheadline).foregroundStyle(.secondary) }
                    if let n = info?.seasons.count, n > 0 {
                        Text(n == 1 ? "1 temporada" : "\(n) temporadas").font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let r = series.rating, let v = Double(r), v > 0 {
                        Label(String(format: "%.1f", v), systemImage: "star.fill").font(.subheadline).foregroundStyle(.yellow)
                    }
                    HStack(spacing: 16) {
                        let listed = session.inList(Session.listKey(series: series.id))
                        Button { session.toggleList(Session.listKey(series: series.id)) } label: {
                            Label(listed ? "En mi lista" : "Mi lista", systemImage: listed ? "bookmark.fill" : "bookmark")
                        }
                        .buttonStyle(.borderless)
                        if let t = trailerURL(series.trailer) {
                            Link(destination: t) { Label("Tráiler", systemImage: "play.rectangle") }
                        }
                    }
                    .font(.subheadline)
                    .padding(.top, 2)
                }
                .padding(.top, 74)
            }
            .padding(.horizontal, 4)
            .padding(.top, -90)
            if let p = info?.plot ?? series.plot, !p.isEmpty {
                ExpandableText(text: p, lineLimit: 4).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 14)
            }
        }
        .padding(.bottom, 6)
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
        let all = info.allEpisodes
        guard let last = all.lastIndex(where: { isWatched($0.1, season: $0.0) }), last + 1 < all.count else { return nil }
        return all[last + 1]
    }

    private func play(_ ep: Episode, from ms: Int, season forced: Int? = nil) {
        guard let api = session.api else { return }
        let item = PlayItem.episode(series: series, ep: ep, season: forced ?? seasonOf(ep), from: ms, api: api, info: info)
        playing = Downloads.shared.preferLocal(item, id: "e\(ep.id)")   // descargado: desde el iPhone
    }

    private func download(_ ep: Episode) {
        guard let api = session.api else { return }
        let s = seasonOf(ep)
        Downloads.shared.enqueue(DownloadItem(id: "e\(ep.id)", kind: "series", title: series.title,
                                              subtitle: "T\(s) · E\(ep.number) · \(ep.title.cleanTitle)",
                                              image: ep.image ?? series.cover, remote: api.episodeURL(ep).absoluteString,
                                              ext: ep.ext, resumeName: series.name, itemId: ep.id,
                                              season: s, episode: ep.number))
    }

    /// Este capítulo y los siguientes de la temporada que no estén vistos.
    private func downloadSeason(from ep: Episode) {
        for e in info?.episodes[season] ?? [] where e.number >= ep.number && !isWatched(e) {
            download(e)
        }
    }
}

struct EpisodeRow: View {
    let episode: Episode
    let progress: Double?
    var watched = false
    /// Crece con el tamaño de letra del iPhone (con letra grande "12" no cabía).
    @ScaledMetric(relativeTo: .headline) private var numberWidth: CGFloat = 34

    private var thumb: String? { episode.image.flatMap { $0.hasPrefix("http") ? $0 : nil } }

    var body: some View {
        HStack(spacing: 12) {
            if let thumb {
                // Fotograma del capítulo, con el progreso abajo y una marca si ya está visto.
                Color.clear
                    .frame(width: 112, height: 63)
                    .overlay { RemoteImage(url: thumb, maxPixel: 360) }
                    .overlay {
                        if watched {
                            Color.black.opacity(0.45)
                            Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let progress {
                            GeometryReader { g in
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.black.opacity(0.5))
                                    Rectangle().fill(Color.accentColor).frame(width: g.size.width * progress)
                                }
                            }
                            .frame(height: 4)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Group {
                    if watched {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                    } else {
                        Text("\(episode.number)").font(.headline.monospacedDigit()).foregroundStyle(Color.accentColor)
                    }
                }
                .frame(width: numberWidth)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(thumb != nil || watched ? "\(episode.number). \(episode.title.cleanTitle)" : episode.title.cleanTitle)
                    .lineLimit(2)
                    .foregroundStyle(watched ? Color.secondary : Color.primary)
                if let d = episode.durationSecs, d > 0 {
                    Text("\(d / 60) min").font(.caption).foregroundStyle(.secondary)
                }
                if thumb == nil, let progress { ProgressView(value: progress).tint(.accentColor) }
            }
            Spacer()
            Image(systemName: "play.circle").foregroundStyle(Color.accentColor)
        }
        .contentShape(Rectangle())
    }
}
