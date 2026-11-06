import SwiftUI

// MARK: - Búsqueda

extension String {
    /// Para buscar: sin mayúsculas ni tildes ("Acción" = "accion").
    var searchKey: String { folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil) }
}

/// Índice de búsqueda: los nombres se normalizan una sola vez al cargar la lista (no en cada letra)
/// y se busca por palabras en cualquier orden; primero lo que empieza por lo escrito.
struct SearchIndex<T> {
    private var keys: [String] = []
    private var items: [T] = []

    init() {}
    init(_ list: [T], name: (T) -> String) {
        items = list
        keys = list.map { name($0).searchKey }
    }

    var isEmpty: Bool { items.isEmpty }

    func search(_ query: String, limit: Int) -> [T] {
        let words = query.searchKey.split(separator: " ").map(String.init)
        guard let first = words.first else { return [] }
        var starts: [T] = [], others: [T] = []
        for i in keys.indices {
            let k = keys[i]
            guard words.allSatisfy({ k.contains($0) }) else { continue }
            if k.hasPrefix(first) {
                starts.append(items[i])
                if starts.count >= limit { break }
            } else if others.count < limit {
                others.append(items[i])
            }
        }
        return Array((starts + others).prefix(limit))
    }
}

/// Prepara el índice fuera del hilo principal (no bloquea la pantalla con 12.000 títulos).
func makeSearchIndex<T>(_ list: [T], _ name: (T) -> String) async -> SearchIndex<T> {
    SearchIndex(list, name: name)
}

/// Búsqueda con espera: solo se busca cuando se deja de escribir un momento.
/// nil si se ha seguido escribiendo (se mantienen los resultados de antes, sin parpadeos).
@MainActor
func debouncedSearch<T>(_ query: String, in index: SearchIndex<T>, limit: Int) async -> [T]? {
    let q = query.trimmingCharacters(in: .whitespaces)
    guard !q.isEmpty else { return [] }
    try? await Task.sleep(nanoseconds: 250_000_000)
    if Task.isCancelled { return nil }
    return index.search(q, limit: limit)
}
