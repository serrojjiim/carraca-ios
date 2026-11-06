import Foundation

extension String {
    /// "ES - Ice Age 4 (2012)" -> "Ice Age 4 (2012)"
    var cleanTitle: String {
        if let r = range(of: #"^[A-Z]{2,4}\s*[-|:]\s+"#, options: .regularExpression) {
            return String(self[r.upperBound...])
        }
        return self
    }

    /// "Friends (US) - S01E20 - El del dentista" -> "Friends (US)"
    var seriesBaseName: String {
        if let r = range(of: #"\s*-?\s*S\d{1,2}\s*E\d{1,3}.*$"#, options: .regularExpression) {
            return String(self[..<r.lowerBound])
        }
        return self
    }

    /// "Ice Age 4 (2012)" -> 2012 (o el primer año razonable que aparezca).
    var yearGuess: Int? {
        guard let r = range(of: #"(19[3-9]\d|20[0-4]\d)"#, options: .regularExpression) else { return nil }
        return Int(self[r])
    }

    /// Como seriesBaseName pero sin distinguir mayúsculas ("s01e20" también vale).
    var seriesBaseNameAnyCase: String {
        if let r = range(of: #"\s*-?\s*[Ss]\d{1,2}\s*[Ee]\d{1,3}.*$"#, options: .regularExpression) {
            return String(self[..<r.lowerBound])
        }
        return self
    }

    /// "TF: GH 24H 1 + ᴿᴬᵂ" -> nombre "GH 24H 1 +" + etiqueta "RAW" (sin cambiar mayúsculas).
    var channelLabel: CategoryLabel {
        var s = self
        if let r = s.range(of: #"^[A-Z0-9]{1,8}\s*:\s+"#, options: .regularExpression) {
            s = String(s[r.upperBound...])
        }
        let parts = s.splitSuperscriptTags
        return CategoryLabel(name: parts.0.isEmpty ? self : parts.0, tag: parts.1)
    }

    /// Palabras normales por un lado y las de letras pequeñitas (etiquetas) por otro.
    private var splitSuperscriptTags: (String, String?) {
        var words: [String] = []
        var tags: [String] = []
        for token in split(separator: " ") {
            let sup = token.filter { superscriptLetters[$0] != nil }.count
            if sup > 0 && sup * 2 >= token.count {
                tags.append(token.map { c in superscriptLetters[c].map { String($0) } ?? c.uppercased() }.joined())
            } else {
                words.append(String(token))
            }
        }
        return (words.joined(separator: " "), tags.isEmpty ? nil : tags.joined(separator: " "))
    }

    /// "ES| CABEL TV SPORTS ᴿᴬᵂ" -> nombre "Cabel TV Sports" + etiqueta "RAW".
    var categoryLabel: CategoryLabel {
        var s = self
        if let r = s.range(of: #"^[A-Z]{2,4}\s*[-|:]\s*"#, options: .regularExpression) {
            s = String(s[r.upperBound...])
        }
        let parts = s.splitSuperscriptTags
        var name = parts.0
        if name == name.uppercased() {
            // TODO EN MAYÚSCULAS -> "Películas 2026" (las siglas cortas se quedan: TV, HBO, 4K)
            name = name.split(separator: " ").map { w in
                w.count <= 3 ? String(w) : String(w.prefix(1)) + w.dropFirst().lowercased()
            }.joined(separator: " ")
        }
        if name.isEmpty { name = self }
        return CategoryLabel(name: name, tag: parts.1)
    }
}

struct CategoryLabel: Hashable {
    let name: String
    let tag: String?
}

/// Letras "pequeñitas" que el proveedor usa de adorno en los nombres de categoría.
private let superscriptLetters: [Character: Character] = [
    "ᴬ": "A", "ᴮ": "B", "ᴰ": "D", "ᴱ": "E", "ᴳ": "G", "ᴴ": "H", "ᴵ": "I", "ᴶ": "J", "ᴷ": "K",
    "ᴸ": "L", "ᴹ": "M", "ᴺ": "N", "ᴼ": "O", "ᴾ": "P", "ᴿ": "R", "ᵀ": "T", "ᵁ": "U", "ⱽ": "V", "ᵂ": "W",
    "ᵃ": "A", "ᵇ": "B", "ᶜ": "C", "ᵈ": "D", "ᵉ": "E", "ᶠ": "F", "ᵍ": "G", "ʰ": "H", "ⁱ": "I", "ʲ": "J",
    "ᵏ": "K", "ˡ": "L", "ᵐ": "M", "ⁿ": "N", "ᵒ": "O", "ᵖ": "P", "ʳ": "R", "ˢ": "S", "ᵗ": "T", "ᵘ": "U",
    "ᵛ": "V", "ʷ": "W", "ˣ": "X", "ʸ": "Y", "ᶻ": "Z",
    "⁰": "0", "¹": "1", "²": "2", "³": "3", "⁴": "4", "⁵": "5", "⁶": "6", "⁷": "7", "⁸": "8", "⁹": "9",
]
