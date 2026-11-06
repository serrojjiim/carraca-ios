import SwiftUI

/// Texto largo (sinopsis) recortado a unas líneas con "Leer más" si no cabe.
struct ExpandableText: View {
    let text: String
    var lineLimit = 4
    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text)
                .lineLimit(expanded ? nil : lineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    // mide el texto entero (oculto) para saber si hace falta el botón
                    GeometryReader { limited in
                        Text(text)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: limited.size.width, alignment: .leading)
                            .background {
                                GeometryReader { full in
                                    Color.clear
                                        .onAppear { if !expanded { truncated = full.size.height > limited.size.height + 2 } }
                                        .onChange(of: limited.size.width) { _ in
                                            if !expanded { truncated = full.size.height > limited.size.height + 2 }
                                        }
                                }
                            }
                            .hidden()
                    }
                }
            if truncated || expanded {
                Button(expanded ? "Leer menos" : "Leer más") {
                    withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .buttonStyle(.borderless)
            }
        }
    }
}
