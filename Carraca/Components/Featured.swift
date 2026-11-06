import SwiftUI

/// Una diapositiva de la portada destacada.
struct FeaturedSlide {
    let id: String
    let title: String
    let subtitle: String
    let backdrop: String?
    let poster: String?
}

/// Portada destacada en carrusel (pasa sola cada 7 s; al deslizar a mano se reinicia la cuenta).
/// Si la diapositiva no trae imagen horizontal se pide al tocarle el turno (`backdrop`) y,
/// mientras, se ve la carátula desenfocada de fondo con la carátula al lado.
struct FeaturedCarousel<Item: Hashable>: View {
    let items: [Item]
    let height: CGFloat
    let slide: (Item) -> FeaturedSlide
    var backdrop: ((Item) async -> String?)? = nil

    @State private var page = 0
    @State private var loaded: [String: String] = [:]
    @State private var asked: Set<String> = []
    /// Con el reproductor encima no se ve: ni pasa solo ni pide imágenes.
    @ObservedObject private var presence = PlayerPresence.shared

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let s = slide(item)
                NavigationLink(value: item) { FeaturedCard(slide: s, backdrop: s.backdrop ?? loaded[s.id], height: height) }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: items.count > 1 ? .always : .never))
        .frame(height: height)
        .task(id: presence.open ? -1 : page) {
            guard !presence.open else { return }
            await fetchBackdrop(page)
            guard items.count > 1 else { return }
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { page = (page + 1) % items.count }
        }
    }

    @MainActor
    private func fetchBackdrop(_ i: Int) async {
        guard let backdrop, items.indices.contains(i) else { return }
        let s = slide(items[i])
        guard s.backdrop == nil, asked.insert(s.id).inserted else { return }
        if let b = await backdrop(items[i]) { loaded[s.id] = b }
    }
}

private struct FeaturedCard: View {
    let slide: FeaturedSlide
    let backdrop: String?
    let height: CGFloat

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .overlay {
                if let b = backdrop {
                    RemoteImage(url: b, maxPixel: 1400).transition(.opacity)
                } else {
                    RemoteImage(url: slide.poster).blur(radius: 26).opacity(0.75)
                }
            }
            .overlay {
                LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .center, endPoint: .bottom)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(alignment: .bottom, spacing: 14) {
                    if backdrop == nil, slide.poster != nil {
                        Color.clear
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .frame(height: height * 0.6)
                            .overlay { RemoteImage(url: slide.poster) }
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(slide.title).font(.title2.bold()).lineLimit(2)
                        if !slide.subtitle.isEmpty {
                            Text(slide.subtitle).font(.subheadline).opacity(0.85).lineLimit(1)
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding()
                .padding(.bottom, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .animation(.easeInOut(duration: 0.4), value: backdrop)
            .contentShape(Rectangle())
    }
}

/// "2024 · ★ 7.1" bajo el título de la portada destacada.
func featuredSubtitle(_ m: VodStream) -> String {
    var parts: [String] = []
    if let y = m.year { parts.append(String(y)) }
    if m.score > 0 && m.score < 10 { parts.append(String(format: "★ %.1f", m.score)) }
    return parts.joined(separator: " · ")
}
