import SwiftUI

struct MovieDetailView: View {
    let movie: VodStream
    @EnvironmentObject private var session: Session
    /// Sin observar: el estado de la descarga lo pinta MovieDownloadRow (que es lo único que cambia).
    private var downloads: Downloads { Downloads.shared }
    @State private var info: VodInfo?
    @State private var playing: PlayItem?
    @State private var showDownload = false

    var body: some View {
        ScrollView {
            // Fondo: la imagen horizontal de la peli o, si no hay, la carátula desenfocada.
            Color.clear
                .frame(height: 230)
                .overlay {
                    if let b = info?.backdrop {
                        RemoteImage(url: b, maxPixel: 1400)
                    } else {
                        RemoteImage(url: movie.icon ?? info?.image).blur(radius: 28).opacity(0.7)
                    }
                }
                .overlay {
                    LinearGradient(colors: [.clear, Color("LaunchBg").opacity(0.6), Color("LaunchBg")],
                                   startPoint: .top, endPoint: .bottom)
                }
                .clipped()
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 16) {
                    Color.clear
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .frame(width: 140)
                        .overlay { RemoteImage(url: movie.icon ?? info?.image) }
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .shadow(color: .black.opacity(0.5), radius: 12, y: 6)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(movie.title).font(.title3.bold())
                        if let g = info?.genre, !g.isEmpty { Text(g).font(.subheadline).foregroundStyle(.secondary) }
                        if let r = info?.release, !r.isEmpty { Text(r).font(.subheadline).foregroundStyle(.secondary) }
                        if let d = info?.duration, !d.isEmpty { Label(d, systemImage: "clock").font(.subheadline).foregroundStyle(.secondary) }
                        if let r = movie.rating, let v = Double(r), v > 0 {
                            Label(String(format: "%.1f", v), systemImage: "star.fill").font(.subheadline).foregroundStyle(.yellow)
                        }
                        if session.resumeEnabled {
                            let seen = session.isWatched(movie: movie.name)
                            Button {
                                session.setWatched(type: "movie", name: movie.name, on: !seen)
                            } label: {
                                Label(seen ? "Vista" : "Marcar como vista", systemImage: seen ? "checkmark.circle.fill" : "checkmark.circle")
                                    .font(.subheadline)
                                    .foregroundStyle(seen ? Color.green : Color.accentColor)
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                        let listed = session.inList(Session.listKey(movie: movie.id))
                        Button { session.toggleList(Session.listKey(movie: movie.id)) } label: {
                            Label(listed ? "En mi lista" : "Añadir a mi lista", systemImage: listed ? "bookmark.fill" : "bookmark")
                                .font(.subheadline)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        if let t = trailerURL(info?.trailer ?? movie.trailer) {
                            Link(destination: t) { Label("Ver tráiler", systemImage: "play.rectangle").font(.subheadline) }
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

                downloadButton

                if let p = info?.plot, !p.isEmpty { ExpandableText(text: p, lineLimit: 5).foregroundStyle(.secondary) }
                if let d = info?.director, !d.isEmpty { Text("Dirección: \(d)").font(.footnote).foregroundStyle(.secondary) }
                if let cast = info?.castList, !cast.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Reparto").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(cast.prefix(15), id: \.self) { name in
                                    Text(name)
                                        .font(.footnote)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Capsule().fill(Color.white.opacity(0.08)))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
            .padding(.top, -110)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea(edges: .top)
        .background(Color("LaunchBg").ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .task { info = try? await session.api?.vodInfo(movie.id) }
        .sheet(isPresented: $showDownload) { DownloadOptionsView(movie: movie) }
        .fullScreenCover(item: $playing, onDismiss: { Task { await session.refreshResume() } }) { PlayerView(item: $0) }
    }

    /// Descargar / descargando / descargada (en ese caso se reproduce el fichero local).
    @ViewBuilder
    private var downloadButton: some View {
        if !session.isM3U {
            MovieDownloadRow(id: "m\(movie.id)") { showDownload = true }
        }
    }

    /// Si está descargada, se ve desde el iPhone (sin gastar datos ni la conexión de la cuenta).
    private func play(from ms: Int) {
        guard let api = session.api else { return }
        playing = Downloads.shared.preferLocal(PlayItem.movie(movie, from: ms, api: api), id: "m\(movie.id)")
    }
}

/// Estado de la descarga de una peli (lo único de la ficha que cambia mientras se descarga).
private struct MovieDownloadRow: View {
    let id: String
    let onDownload: () -> Void
    @ObservedObject private var downloads = Downloads.shared

    var body: some View {
        if let d = downloads.item(id) {
            HStack {
                switch d.state {
                case .done: Label("Descargada · \(byteText(d.total))", systemImage: "arrow.down.circle.fill").foregroundStyle(.green)
                case .downloading: Label("Descargando \(Int(d.progress * 100)) %", systemImage: "arrow.down.circle")
                default: Label("En descargas", systemImage: "arrow.down.circle.dotted")
                }
                Spacer()
                Button(role: .destructive) { downloads.remove(d.id) } label: { Image(systemName: "trash").hitTarget() }
                    .accessibilityLabel("Borrar descarga")
            }
            .font(.subheadline)
        } else {
            Button(action: onDownload) {
                Label("Descargar", systemImage: "arrow.down.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered).controlSize(.large)
        }
    }
}
