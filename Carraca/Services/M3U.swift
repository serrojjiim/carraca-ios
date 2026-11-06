import Foundation

// MARK: - Listas M3U

enum M3U {
    /// Texto en UTF-8 (o Latin-1 si no lo es).
    static func parse(data: Data) -> [LiveStream] {
        guard let t = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return [] }
        return parse(t)
    }

    /// #EXTINF:-1 tvg-logo="..." group-title="Deportes",Nombre  ->  siguiente línea = URL
    static func parse(_ text: String) -> [LiveStream] {
        var out: [LiveStream] = []
        var name = "", logo: String?, group = "Sin categoría"
        var pending = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXTINF") {
                logo = attr("tvg-logo", in: line)
                group = attr("group-title", in: line) ?? "Sin categoría"
                if let comma = line.lastIndex(of: ",") {
                    name = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespaces)
                } else {
                    name = ""
                }
                pending = true
            } else if !line.hasPrefix("#"), pending, let url = URL(string: line) {
                let n = name.isEmpty ? "Canal \(out.count + 1)" : name
                out.append(LiveStream(id: out.count + 1, name: n, icon: (logo?.isEmpty ?? true) ? nil : logo,
                                      categoryId: group, directURL: url))
                pending = false
            }
        }
        return out
    }

    private static func attr(_ key: String, in line: String) -> String? {
        guard let r = line.range(of: key + "=\"") else { return nil }
        let rest = line[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }
}
