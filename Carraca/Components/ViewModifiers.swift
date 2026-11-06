import SwiftUI

private struct SettingsButton: ViewModifier {
    @State private var show = false
    @State private var search = false
    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 0) {
                        Button { search = true } label: { Image(systemName: "magnifyingglass").hitTarget() }
                            .accessibilityLabel("Buscar en todo")
                        Button { show = true } label: { Image(systemName: "gearshape").hitTarget() }
                            .accessibilityLabel("Ajustes")
                    }
                }
            }
            .sheet(isPresented: $show) { SettingsView() }
            .sheet(isPresented: $search) { GlobalSearchView() }
    }
}

extension View {
    func withSettings() -> some View { modifier(SettingsButton()) }

    /// Zona de toque de al menos 44 × 44 puntos (lo que pide Apple) aunque el icono sea pequeño.
    func hitTarget() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
    }

    /// Lo mismo en los avisos finos (saludo, caducidad): la zona de toque crece sin hacer el aviso más alto.
    func bannerHitTarget() -> some View {
        frame(minWidth: 24, minHeight: 24).padding(10).contentShape(Rectangle()).padding(-10)
    }
}

// MARK: - Directo

/// Una lista se ha actualizado por detrás (P1): las pestañas que la usan se recargan (de la caché ya nueva).
/// Varias seguidas (categorías + lista) se juntan en una sola recarga.
private struct ListRefreshWatcher: ViewModifier {
    let names: Set<String>
    let reload: () async -> Void
    @State private var tick = 0

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: XtreamAPI.listRefreshed)) { n in
                if let k = n.object as? String, names.contains(k) { tick += 1 }
            }
            .task(id: tick) {
                guard tick > 0 else { return }
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                await reload()
            }
    }
}

extension View {
    func onListRefreshed(_ names: Set<String>, reload: @escaping () async -> Void) -> some View {
        modifier(ListRefreshWatcher(names: names, reload: reload))
    }
}
