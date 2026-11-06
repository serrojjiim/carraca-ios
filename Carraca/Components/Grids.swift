import SwiftUI

/// Orden de las cuadrículas de pelis y series.
enum GridSort: String, CaseIterable {
    case recent = "Más recientes", az = "A–Z", rating = "Mejor nota", year = "Año"
}

/// Clave para recalcular el orden de una cuadrícula solo cuando cambia algo (no en cada repintado).
func gridKey<T: Identifiable>(_ items: [T], _ parts: String...) -> String {
    "\(items.count)|\(String(describing: items.first?.id))|\(String(describing: items.last?.id))|" + parts.joined(separator: "|")
}

func sortVod(_ items: [VodStream], _ sort: GridSort) -> [VodStream] {
    switch sort {
    case .recent: return items
    case .az: return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .rating: return items.sorted { $0.score > $1.score }
    case .year: return items.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }
}

struct VodGrid: View {
    let items: [VodStream]
    @EnvironmentObject private var session: Session
    @State private var sort = GridSort.recent
    /// Ya ordenadas: el orden se calcula fuera del hilo principal y solo al cambiar.
    @State private var sorted: [VodStream]

    init(items: [VodStream]) {
        self.items = items
        _sorted = State(initialValue: items)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 16) {
                ForEach(sorted) { v in
                    NavigationLink(value: v) {
                        PosterCell(title: v.title, image: v.icon,
                                   progress: session.resumeFor(movie: v.name).map { Double($0.pro) / 100 },
                                   watched: session.isWatched(movie: v.name))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Ordenar", selection: $sort) {
                        ForEach(GridSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Ordenar")
            }
        }
        .task(id: gridKey(items, sort.rawValue)) {
            let list = items, s = sort
            if s == .recent { sorted = list; return }
            sorted = await Task.detached(priority: .userInitiated) { sortVod(list, s) }.value
        }
    }
}

func filterSortSeries(_ items: [SeriesItem], _ sort: GridSort, _ genre: String) -> [SeriesItem] {
    let list = genre.isEmpty ? items : items.filter { $0.genres.contains(genre) }
    switch sort {
    case .recent: return list
    case .az: return list.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    case .rating: return list.sorted { $0.score > $1.score }
    case .year: return list.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
    }
}

struct SeriesGrid: View {
    let items: [SeriesItem]
    @State private var sort = GridSort.recent
    @State private var genre = ""
    /// Ya filtradas y ordenadas (se recalculan solo al cambiar lista, orden o género).
    @State private var shown: [SeriesItem]
    @State private var genres: [String] = []

    init(items: [SeriesItem]) {
        self.items = items
        _shown = State(initialValue: items)
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: posterColumns, spacing: 16) {
                ForEach(shown) { s in
                    NavigationLink(value: s) { PosterCell(title: s.title, image: s.cover) }
                        .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Ordenar", selection: $sort) {
                        ForEach(GridSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if !genres.isEmpty {
                        Picker("Género", selection: $genre) {
                            Text("Todos los géneros").tag("")
                            ForEach(genres, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } label: {
                    Image(systemName: genre.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Ordenar y filtrar")
            }
        }
        .task(id: gridKey(items)) {
            let list = items
            genres = await Task.detached(priority: .utility) { () -> [String] in
                var count: [String: Int] = [:]
                for s in list { for g in s.genres { count[g, default: 0] += 1 } }
                return count.filter { $0.value >= 2 }.keys.sorted()
            }.value
        }
        .task(id: gridKey(items, sort.rawValue, genre)) {
            let list = items, s = sort, g = genre
            if s == .recent && g.isEmpty { shown = list; return }
            shown = await Task.detached(priority: .userInitiated) { filterSortSeries(list, s, g) }.value
        }
    }
}
