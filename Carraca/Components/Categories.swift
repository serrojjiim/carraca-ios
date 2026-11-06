import SwiftUI

/// Fila de categoría de directo (vista lista): logo del primer canal + nombre + nº de canales.
struct CategoryListRow: View {
    let name: String
    let tag: String?
    let count: Int
    let logo: String?
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let symbol, logo == nil {
                    Image(systemName: symbol).foregroundStyle(symbol == "star.fill" ? Color.yellow : Color.accentColor)
                } else {
                    RemoteImage(url: logo, contentMode: .fit).padding(3)
                }
            }
            .frame(width: 52, height: 34)
            .background(Color.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(name).lineLimit(1)
            if let tag { TagChip(text: tag) }
            Spacer(minLength: 6)
            Text("\(count)").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

/// Tarjeta de categoría de directo: logos de sus primeros canales + nombre + nº de canales.
struct CategoryCard: View {
    let name: String
    let tag: String?
    let count: Int
    let logos: [String]
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ForEach(0..<4, id: \.self) { i in
                    Group {
                        if i < logos.count {
                            RemoteImage(url: logos[i], contentMode: .fit).padding(3)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.caption).foregroundStyle(.yellow) }
                Text(name).font(.subheadline.weight(.semibold)).lineLimit(1)
                if let tag { TagChip(text: tag) }
            }
            Text("\(count) canales").font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

/// iPad: menú lateral de Películas / Series (Inicio + categorías con nº de títulos).
struct VodSidebar: View {
    let categories: [Category]
    let counts: [String: Int]
    @Binding var selection: Category?

    var body: some View {
        List(selection: $selection) {
            Label("Inicio", systemImage: "house").tag(Category.home)
            Section("Categorías") {
                ForEach(categories) { c in
                    let l = c.label
                    HStack(spacing: 6) {
                        Text(l.name).lineLimit(1)
                        if let t = l.tag { TagChip(text: t) }
                        Spacer(minLength: 6)
                        Text("\(counts[c.id] ?? 0)").font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(c)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

// MARK: - Saltar a una categoría (iPhone)

/// Lista de categorías (con buscador) para ir directamente a una sin bajar por todas las filas.
struct CategoryJumpSheet: View {
    let title: String
    let categories: [Category]
    let counts: [String: Int]
    let onPick: (Category) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var filtered: [Category] {
        let q = query.trimmingCharacters(in: .whitespaces).searchKey
        return q.isEmpty ? categories : categories.filter { $0.label.name.searchKey.contains(q) }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { c in
                Button {
                    onPick(c)
                    dismiss()
                } label: {
                    HStack(spacing: 6) {
                        Text(c.label.name).lineLimit(1).foregroundStyle(.primary)
                        if let t = c.label.tag { TagChip(text: t) }
                        Spacer(minLength: 6)
                        Text("\(counts[c.id] ?? 0)").font(.caption).foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
            }
            .listStyle(.plain)
            .overlay {
                if filtered.isEmpty { Text("Ninguna categoría con ese nombre.").foregroundStyle(.secondary) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Buscar categoría")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .seasonTint()
    }
}
