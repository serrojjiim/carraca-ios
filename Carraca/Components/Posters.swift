import SwiftUI

/// Carátula que falta: degradado (color sacado del título, siempre el mismo) con el título.
struct TitleTile: View {
    let title: String

    private var hue: Double {
        let h = title.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return Double(h % 360) / 360
    }

    var body: some View {
        LinearGradient(colors: [Color(hue: hue, saturation: 0.55, brightness: 0.42),
                                Color(hue: hue, saturation: 0.65, brightness: 0.18)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "film").font(.title3).opacity(0.5)
                    Text(title)
                        .font(.footnote.weight(.bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(.white.opacity(0.92))
                .padding(10)
            }
    }
}

struct PosterCell: View {
    let title: String
    let image: String?
    var progress: Double? = nil
    var watched = false
    /// Botón ▶ encima: tocar reproduce (no abre la ficha).
    var playBadge = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay { RemoteImage(url: image, title: title) }
                .overlay {
                    if playBadge {
                        Image(systemName: "play.fill")
                            .font(.body.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(.black.opacity(0.45), in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.7), lineWidth: 1.5))
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress {
                        ProgressView(value: progress).tint(.accentColor).padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if watched { WatchedBadge().padding(5) }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(title)
                .font(.caption)
                .lineLimit(2)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

let posterColumns = [GridItem(.adaptive(minimum: 108, maximum: 170), spacing: 12)]

/// Marca de "ya visto" sobre una carátula.
struct WatchedBadge: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(Color.green))
    }
}

/// Etiqueta pequeña (RAW, 4K, 60FPS…) sacada del nombre de la categoría.
struct TagChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }
}

/// Fila horizontal de carátulas (estilo Netflix) con "Ver todo".
struct PosterRail<T: Identifiable & Hashable>: View {
    let title: String
    let tag: String?
    let seeAll: Category?
    let count: Int
    let items: [T]
    let width: CGFloat
    let titleOf: (T) -> String
    let imageOf: (T) -> String?
    let progressOf: (T) -> Double?
    let watchedOf: (T) -> Bool
    /// "Seguir viendo": un toque reproduce directamente; mantener pulsado, "Ver ficha".
    let playOf: ((T) -> Void)?
    let infoOf: ((T) -> Void)?

    init(_ title: String, tag: String? = nil, seeAll: Category? = nil, count: Int = 0, items: [T], width: CGFloat,
         title titleOf: @escaping (T) -> String, image imageOf: @escaping (T) -> String?,
         progress progressOf: @escaping (T) -> Double? = { _ in nil },
         watched watchedOf: @escaping (T) -> Bool = { _ in false },
         play playOf: ((T) -> Void)? = nil, info infoOf: ((T) -> Void)? = nil) {
        self.watchedOf = watchedOf
        self.playOf = playOf
        self.infoOf = infoOf
        self.title = title
        self.tag = tag
        self.seeAll = seeAll
        self.count = count
        self.items = items
        self.width = width
        self.titleOf = titleOf
        self.imageOf = imageOf
        self.progressOf = progressOf
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.title3.bold()).lineLimit(1)
                if let tag { TagChip(text: tag) }
                Spacer(minLength: 8)
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        HStack(spacing: 3) {
                            Text(count > 0 ? "Ver \(count)" : "Ver todo")
                            Image(systemName: "chevron.right")
                        }
                        .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { it in
                        if let playOf {
                            Button { playOf(it) } label: {
                                PosterCell(title: titleOf(it), image: imageOf(it), progress: progressOf(it),
                                           watched: watchedOf(it), playBadge: true)
                                    .frame(width: width)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button { playOf(it) } label: { Label("Continuar", systemImage: "play.fill") }
                                if let infoOf {
                                    Button { infoOf(it) } label: { Label("Ver ficha", systemImage: "info.circle") }
                                }
                            }
                        } else {
                            NavigationLink(value: it) {
                                PosterCell(title: titleOf(it), image: imageOf(it), progress: progressOf(it), watched: watchedOf(it))
                                    .frame(width: width)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
        // carátulas de la fila listas antes de deslizar
        .onAppear { ImageLoader.shared.prefetch(items.prefix(12).map(imageOf)) }
    }
}
