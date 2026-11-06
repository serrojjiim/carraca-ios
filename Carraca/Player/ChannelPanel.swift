import SwiftUI

/// Lista de canales dentro del reproductor (directo): recientes arriba y, debajo, logo, nombre,
/// lo que echan y progreso.
struct ChannelPanel: View {
    let channels: [LiveStream]
    let current: Int?
    let recents: [LiveStream]
    let onPick: (Int) -> Void
    let onPickStream: (LiveStream) -> Void
    let onClose: () -> Void
    @ObservedObject private var guide = GuideStore.shared
    @State private var query = ""
    /// Búsqueda: índice preparado una vez (no se normalizan miles de nombres en cada letra).
    @State private var index = SearchIndex<Int>()
    @State private var indexReady = false
    @State private var hits: [Int]?

    private var rows: [(offset: Int, element: LiveStream)] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let hits else { return Array(channels.enumerated()) }
        return hits.compactMap { i in channels.indices.contains(i) ? (i, channels[i]) : nil }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onClose)
            VStack(spacing: 10) {
                HStack {
                    Text("Canales").font(.headline)
                    Text("\(channels.count)").font(.subheadline).foregroundStyle(.white.opacity(0.6))
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.subheadline.bold()).padding(8)
                            .background(Color.white.opacity(0.12), in: Circle())
                            .hitTarget()
                    }
                    .accessibilityLabel("Cerrar lista")
                }
                if query.isEmpty && !recents.isEmpty { recentRow }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    TextField("Buscar canal", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6)) }
                            .accessibilityLabel("Borrar búsqueda")
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(rows, id: \.offset) { r in
                                row(r.element, selected: r.offset == current)
                                    .id(r.offset)
                                    .onTapGesture { onPick(r.offset) }
                            }
                        }
                    }
                    .onAppear {
                        if let c = current { proxy.scrollTo(c, anchor: .center) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .frame(width: 340)
            .frame(maxHeight: .infinity)
            .background(.ultraThinMaterial, ignoresSafeAreaEdges: [.top, .bottom, .trailing])
            .environment(\.colorScheme, .dark)
        }
        .foregroundStyle(.white)
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width > 60, abs(v.translation.width) > abs(v.translation.height) { onClose() }
        })
        .task {
            let list = channels
            index = await makeSearchIndex(Array(list.indices)) { list[$0].name }
            indexReady = true
        }
        .task(id: query + (indexReady ? "|1" : "|0")) {
            if let r = await debouncedSearch(query, in: index, limit: 5000) { hits = r }
        }
    }

    /// Últimos canales vistos (de cualquier categoría).
    private var recentRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recientes").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recents) { s in
                        Button { onPickStream(s) } label: {
                            VStack(spacing: 4) {
                                RemoteImage(url: s.icon, contentMode: .fit)
                                    .padding(4)
                                    .frame(width: 64, height: 40)
                                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                                Text(s.label.name).font(.caption2).lineLimit(1).frame(width: 64)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s.label.name)
                    }
                }
            }
        }
    }

    private func row(_ s: LiveStream, selected: Bool) -> some View {
        let now = guide.nowNext(s).first
        return HStack(spacing: 10) {
            ChannelLogo(url: s.icon, width: 48, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(s.label.name).font(.subheadline.weight(selected ? .bold : .semibold)).lineLimit(1)
                    if let t = s.label.tag { TagChip(text: t) }
                }
                if let now {
                    Text(now.title).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    ProgramProgress(entry: now).frame(width: 90)
                }
            }
            Spacer(minLength: 0)
            if selected {
                Image(systemName: "play.fill").font(.caption).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Color.accentColor.opacity(0.3) : Color.clear))
        .contentShape(Rectangle())
    }
}
