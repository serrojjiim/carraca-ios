import SwiftUI

// MARK: - Catálogo compartido (películas y series)

/// Un título del catálogo (película o serie): lo que hace falta para ponerlo en filas, buscarlo y ordenarlo.
protocol CatalogTitle: Identifiable, Hashable where ID == Int {
    var name: String { get }
    var categoryId: String { get }
    /// Carátula.
    var poster: String? { get }
    /// Para ordenar de lo más nuevo a lo más antiguo (cuándo se añadió o tuvo capítulo nuevo).
    var freshness: Int { get }
    /// Texto extra con el que se elige la fila del tema de temporada (el género, en series).
    var themeText: String { get }
}

extension VodStream: CatalogTitle {
    var poster: String? { icon }
    var freshness: Int { added }
    var themeText: String { "" }
}

extension SeriesItem: CatalogTitle {
    var poster: String? { cover }
    var freshness: Int { updated }
    var themeText: String { genre ?? "" }
}

/// Una lista del catálogo (todas las películas o todas las series) cargada, ordenada e indexada
/// UNA sola vez para toda la app. Antes Películas, Series, Mi Carraca y el buscador cargaban,
/// ordenaban e indexaban cada uno la suya (hasta 3 índices de 12.000 títulos en memoria).
///
/// La crea MainTabView: cada inicio de sesión empieza con un catálogo vacío (otra cuenta, otras listas).
@MainActor
final class CatalogShelf<Item: CatalogTitle>: ObservableObject {
    typealias Fetch = (XtreamAPI, Bool) async throws -> ([Category], [Item])

    /// Todo, de lo más nuevo a lo más antiguo.
    @Published private(set) var newest: [Item] = []
    /// Categorías con algo dentro (en el orden del servidor) y cuántos títulos tiene cada una.
    @Published private(set) var categories: [Category] = []
    @Published private(set) var counts: [String: Int] = [:]
    /// Títulos de cada categoría, de lo más nuevo a lo más antiguo (incluida la fila del tema de temporada).
    @Published private(set) var byCategory: [String: [Item]] = [:]
    /// Lo que encaja con el tema de temporada ("Especial Navidad", "Noche de miedo"…).
    @Published private(set) var seasonal: [Item] = []
    @Published private(set) var loading = false
    /// Recargando a la fuerza (botón "Recargar listas"): las pantallas lo tapan con un aviso.
    @Published private(set) var reloading = false
    @Published private(set) var error: String?
    /// Sube con cada carga terminada: lo que una pantalla calcula a partir del catálogo se rehace.
    @Published private(set) var version = 0

    private(set) var byID: [Int: Item] = [:]
    /// Por nombre exacto; si se repite, el que tiene carátula.
    private(set) var byName: [String: Item] = [:]
    private(set) var index = SearchIndex<Item>()
    private var catNames: [String: String] = [:]

    private let fetch: Fetch
    private let lists: Set<String>
    private var api: XtreamAPI?
    private var running: Task<Void, Never>?
    private var watcher: Task<Void, Never>?

    var isEmpty: Bool { newest.isEmpty }
    var recent: [Item] { Array(newest.prefix(20)) }

    /// - lists: nombres de las listas de XtreamAPI de las que sale (si se actualizan por detrás, se recarga).
    init(lists: Set<String>, fetch: @escaping Fetch) {
        self.lists = lists
        self.fetch = fetch
        watcher = Task { [weak self] in
            var pending: Task<Void, Never>?
            for await n in NotificationCenter.default.notifications(named: XtreamAPI.listRefreshed) {
                guard let self else { return }
                guard let k = n.object as? String, self.lists.contains(k), let api = self.api else { continue }
                // la lista y sus categorías suelen llegar juntas: una sola recarga
                pending?.cancel()
                pending = Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    await self.load(api, refresh: true)
                }
            }
        }
    }

    deinit { watcher?.cancel() }

    /// Carga si aún no hay nada. Si ya se está cargando (otra pestaña lo pidió), espera a esa carga.
    /// - force: vuelve a descargar (sin caché). - refresh: vuelve a leer la caché (se actualizó por detrás).
    func load(_ api: XtreamAPI?, force: Bool = false, refresh: Bool = false) async {
        guard let api else { return }
        self.api = api
        if let running {
            await running.value
            if !force { return }
        }
        if !force && !refresh && !newest.isEmpty { return }
        let t = Task { await self.read(api, force: force) }
        running = t
        await t.value
        if running == t { running = nil }
    }

    /// "Recargar listas": solo lo que ya se había cargado (lo demás se descargará al abrirlo).
    func reloadIfLoaded(_ api: XtreamAPI?) async {
        guard !newest.isEmpty || error != nil else { return }
        reloading = true
        await load(api, force: true)
        reloading = false
    }

    private func read(_ api: XtreamAPI, force: Bool) async {
        loading = true
        defer { loading = false }
        do {
            let (cats, all) = try await fetch(api, force)
            let newest = all.sorted { $0.freshness > $1.freshness }
            var cnt: [String: Int] = [:]
            var by: [String: [Item]] = [:]
            for it in newest {
                cnt[it.categoryId, default: 0] += 1
                by[it.categoryId, default: []].append(it)
            }
            var ids: [Int: Item] = [:]
            var names: [String: Item] = [:]
            for it in all {
                if ids[it.id] == nil { ids[it.id] = it }
                if names[it.name] == nil || (names[it.name]?.poster == nil && it.poster != nil) { names[it.name] = it }
            }
            counts = cnt
            byCategory = by
            byID = ids
            byName = names
            categories = cats.filter { (cnt[$0.id] ?? 0) > 0 }
            catNames = Dictionary(cats.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            index = await makeSearchIndex(all) { $0.name }
            self.newest = newest
            await updateSeasonal(ThemeStore.shared.current)
            error = nil
            version += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Fila del tema de temporada: títulos cuyo nombre, género o categoría encaja con el tema.
    func updateSeasonal(_ theme: SeasonTheme?) async {
        guard let t = theme, !newest.isEmpty else {
            seasonal = []
            byCategory[SeasonTheme.railCategoryID] = nil
            return
        }
        let names = catNames
        let picks = await seasonalPicks(newest, keywords: t.keywords,
                                        text: { $0.name + " " + $0.themeText + " " + (names[$0.categoryId] ?? "") },
                                        limit: 300)
        seasonal = picks
        byCategory[SeasonTheme.railCategoryID] = picks
    }

    /// Una serie por el nombre con el que se guardó el progreso (a veces lleva el capítulo detrás).
    func find(named name: String) -> Item? {
        byName[name] ?? byName[name.seriesBaseName]
    }
}

extension CatalogShelf where Item == VodStream {
    static func movies() -> CatalogShelf<VodStream> {
        CatalogShelf(lists: ["vod", "vod_cat"]) { api, force in
            let cats = try await api.vodCategories(force: force)
            let all = try await api.vodStreams(force: force)
            return (cats, all)
        }
    }
}

extension CatalogShelf where Item == SeriesItem {
    static func series() -> CatalogShelf<SeriesItem> {
        CatalogShelf(lists: ["series", "series_cat"]) { api, force in
            let cats = try await api.seriesCategories(force: force)
            let all = try await api.series(force: force)
            return (cats, all)
        }
    }
}
