import Foundation

// MARK: - JSON tolerante (los paneles Xtream mezclan números y textos)

extension KeyedDecodingContainer {
    func flexString(_ key: Key) -> String? {
        if let v = try? decodeIfPresent(String.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return String(v) }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return String(v) }
        return nil
    }

    func flexInt(_ key: Key) -> Int? {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        if let s = try? decodeIfPresent(String.self, forKey: key) {
            if let i = Int(s) { return i }
            if let d = Double(s) { return Int(d) }
        }
        return nil
    }

    func flexDouble(_ key: Key) -> Double? {
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return v }
        if let s = try? decodeIfPresent(String.self, forKey: key) { return Double(s) }
        return nil
    }
}

/// Cualquier valor JSON (para poder saltar elementos que no se entienden).
enum JSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "valor JSON desconocido") }
    }
}

/// Array que descarta los elementos rotos en vez de fallar entero.
struct LossyArray<T: Decodable>: Decodable {
    var items: [T] = []

    init(from d: Decoder) throws {
        guard var c = try? d.unkeyedContainer() else { return }
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) {
                items.append(v)
            } else if (try? c.decode(JSONValue.self)) == nil {
                break
            }
        }
    }
}
