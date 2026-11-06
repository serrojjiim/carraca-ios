import SwiftUI

// MARK: - Componentes

struct RemoteImage: View {
    let url: String?
    var contentMode: ContentMode = .fill
    /// Tamaño máximo (px) al que se guarda: pósteres y logos pequeños, fondos más grandes.
    var maxPixel = 480
    /// Carátulas: si no hay imagen (o no carga) se pinta una tarjeta con el título.
    var title: String? = nil
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else if let title, failed || url == nil {
                TitleTile(title: title)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            failed = false
            guard let s = url, let u = URL(string: s) else { image = nil; failed = true; return }
            if let m = ImageLoader.shared.cached(u, maxPixel: maxPixel) { image = m; return }
            image = nil
            let loaded = await ImageLoader.shared.image(u, maxPixel: maxPixel)
            if Task.isCancelled { return }
            withAnimation(.easeIn(duration: 0.15)) {
                image = loaded
                failed = loaded == nil
            }
        }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .overlay {
                if let title {
                    Text(title)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(4)
                        .padding(8)
                } else {
                    Image(systemName: "photo").foregroundStyle(.tertiary)
                }
            }
    }
}

/// Logo de un canal en su recuadro (listas de canales, guía del reproductor…).
struct ChannelLogo: View {
    let url: String?
    var width: CGFloat = 60
    var height: CGFloat = 40

    var body: some View {
        RemoteImage(url: url, contentMode: .fit)
            .frame(width: width, height: height)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
