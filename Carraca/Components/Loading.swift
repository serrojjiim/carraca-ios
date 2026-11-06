import SwiftUI

/// Las pantallas de carga "laten" (se apagan y encienden despacio) mientras llega la lista.
private struct Pulse: ViewModifier {
    @State private var dim = false

    func body(content: Content) -> some View {
        content
            .scrollDisabled(true)
            .opacity(dim ? 0.45 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: dim)
            .onAppear { dim = true }
            .accessibilityLabel("Cargando")
    }
}

/// Pantalla de carga con la forma de lo que va a salir (filas de carátulas grises).
struct SkeletonRails: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(0..<4, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.10)).frame(width: 150, height: 18)
                        HStack(spacing: 12) {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)).frame(width: 112, height: 168)
                            }
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .modifier(Pulse())
    }
}

/// Lo mismo para las tarjetas de categorías de Directo.
struct SkeletonCards: View {
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                ForEach(0..<12, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.07)).frame(height: 100)
                }
            }
            .padding()
        }
        .modifier(Pulse())
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Cargando…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Pantalla de "recargando" encima del contenido mientras se vuelven a descargar las listas.
struct ReloadingOverlay: View {
    var body: some View {
        ZStack {
            Color("LaunchBg").opacity(0.92).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("Recargando listas…").font(.headline)
                Text("Descargando canales, películas y series de nuevo.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .transition(.opacity)
    }
}

struct ErrorView: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Reintentar", action: retry).buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
