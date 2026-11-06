import SwiftUI

// MARK: - Pantalla de catálogo (Películas y Series)

/// Lo común a Películas y Series: cargando / error / buscador / Inicio y la navegación.
/// iPhone: lista con un botón para saltar a una categoría sin bajar por todas las filas.
/// iPad: menú lateral con las categorías para saltar de una a otra.
struct CatalogScreen<Item: CatalogTitle, Grid: View, Detail: View, Home: View>: View {
    @EnvironmentObject private var session: Session
    @Environment(\.horizontalSizeClass) private var hsize
    @ObservedObject private var theme = ThemeStore.shared
    @ObservedObject var shelf: CatalogShelf<Item>
    let title: String
    let searchPrompt: String
    let jumpTitle: String
    @ViewBuilder let grid: ([Item]) -> Grid
    @ViewBuilder let detail: (Item) -> Detail
    @ViewBuilder let home: () -> Home

    @State private var query = ""
    @State private var hits: [Item] = []
    /// iPad: categoría elegida en el menú lateral (Inicio = filas de carátulas).
    @State private var selected: Category? = Category.home
    /// iPhone: saltar a una categoría desde la lista.
    @State private var path = NavigationPath()
    @State private var jump = false
    @State private var jumpTo: Category?

    var body: some View {
        Group {
            if hsize == .regular { splitBody } else { stackBody }
        }
        .task { await shelf.load(session.api) }
        .task(id: query) { if let r = await debouncedSearch(query, in: shelf.index, limit: 300) { hits = r } }
        .task(id: theme.current) { await shelf.updateSeasonal(theme.current) }
        .overlay { if shelf.reloading { ReloadingOverlay() } }
    }

    @ViewBuilder
    private var main: some View {
        if shelf.isEmpty && shelf.loading {
            SkeletonRails()
        } else if shelf.isEmpty, let error = shelf.error {
            ErrorView(message: error) { Task { await shelf.load(session.api, force: true) } }
        } else if !query.isEmpty {
            grid(hits)
        } else {
            home().refreshable { await shelf.load(session.api, force: true) }
        }
    }

    private func categoryGrid(_ cat: Category) -> some View {
        grid(shelf.byCategory[cat.id] ?? []).navigationTitle(cat.label.name)
    }

    private var stackBody: some View {
        NavigationStack(path: $path) {
            main
                .navigationTitle(title)
                .searchable(text: $query, prompt: searchPrompt)
                .navigationDestination(for: Category.self) { categoryGrid($0) }
                .navigationDestination(for: Item.self) { detail($0) }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        if !shelf.categories.isEmpty && query.isEmpty {
                            Button { jump = true } label: { Image(systemName: "list.bullet.indent") }
                                .accessibilityLabel("Ir a una categoría")
                        }
                    }
                }
                .withSettings()
        }
        .sheet(isPresented: $jump, onDismiss: {
            if let c = jumpTo { path.append(c); jumpTo = nil }
        }) {
            CategoryJumpSheet(title: jumpTitle, categories: shelf.categories, counts: shelf.counts) { jumpTo = $0 }
        }
    }

    private var splitBody: some View {
        NavigationSplitView {
            VodSidebar(categories: shelf.categories, counts: shelf.counts, selection: $selected)
                .navigationTitle(title)
                .searchable(text: $query, placement: .sidebar, prompt: searchPrompt)
                .withSettings()
        } detail: {
            NavigationStack {
                Group {
                    if query.isEmpty, let cat = selected, cat != Category.home {
                        categoryGrid(cat)
                    } else {
                        main.navigationTitle(query.isEmpty ? "Inicio" : "Resultados")
                    }
                }
                .navigationDestination(for: Category.self) { categoryGrid($0) }
                .navigationDestination(for: Item.self) { detail($0) }
            }
            .id(selected?.id)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
