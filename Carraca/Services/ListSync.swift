import Foundation
import CryptoKit

// MARK: - Favoritos y "Mi lista" entre dispositivos (/sync.php del servidor Carraca)

/// Un cambio pendiente. Se borra de la cola solo cuando el servidor lo ha aceptado.
struct SyncOp: Codable, Equatable {
    /// Identificador local (no se envía): permite quitar de la cola solo lo que se envió de verdad.
    var uid: String
    /// "fav" (favoritos) o "list" (Mi lista).
    var k: String
    /// Clave del elemento: favoritos "x<id>" o URL directa; Mi lista "m<id>" / "s<id>" (igual que Android).
    var id: String
    var on: Bool
    /// Epoch en segundos. El servidor gana la hora más nueva por (tipo, id).
    var ts: Int
}

/// Cola pendiente guardada por usuario (no por servidor: si el servidor cambia, la cola sigue).
enum SyncQueue {
    private static func key(_ user: String) -> String { "carraca.sync.q." + user.lowercased() }

    /// Marca de "primera sincronización hecha" en este aparato.
    static func initKey(_ user: String) -> String { "carraca.sync.init." + user.lowercased() }

    static func load(_ user: String) -> [SyncOp] {
        guard let d = UserDefaults.standard.data(forKey: key(user)),
              let ops = try? JSONDecoder().decode([SyncOp].self, from: d) else { return [] }
        return ops
    }

    static func save(_ ops: [SyncOp], user: String) {
        if ops.isEmpty {
            UserDefaults.standard.removeObject(forKey: key(user))
        } else if let d = try? JSONEncoder().encode(ops) {
            UserDefaults.standard.set(d, forKey: key(user))
        }
    }

    /// Una sola operación por elemento: la última (dos toques seguidos no dejan dos "ts" iguales).
    static func enqueue(_ op: SyncOp, into ops: [SyncOp]) -> [SyncOp] {
        var out = ops.filter { !($0.k == op.k && $0.id == op.id) }
        out.append(op)
        return out
    }
}

/// Llamada HTTP a /sync.php. No toca el estado de la app: eso lo hace Session.
enum SyncService {
    static var url: URL { URL(string: AppConfig.panel + "/sync.php")! }

    enum Result {
        case ok(fav: [String]?, list: [String]?)
        /// 403: la contraseña no coincide con la de la cuenta; no se reintenta hasta volver a entrar.
        case forbidden
        /// Sin red o respuesta rara: lo pendiente se queda para la próxima vez.
        case failed
    }

    private struct Reply: Decodable {
        let ok: Bool?
        let fav: [String]?
        let list: [String]?
    }

    /// sha256 hex de "usuario:contraseña" (credenciales Xtream tal cual). Solo viaja en el cuerpo.
    static func token(user: String, pass: String) -> String {
        let digest = SHA256.hash(data: Data((user + ":" + pass).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func send(user: String, pass: String, ops: [SyncOp]) async -> Result {
        var body: [String: Any] = [:]
        body["user"] = user
        body["token"] = token(user: user, pass: pass)
        body["ops"] = ops.map { (op: SyncOp) -> [String: Any] in
            ["k": op.k, "id": op.id, "on": op.on, "ts": op.ts]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return .failed }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 25
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data

        do {
            let (respData, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 403 { return .forbidden }
            guard code == 200,
                  let reply = try? JSONDecoder().decode(Reply.self, from: respData),
                  reply.ok == true else { return .failed }
            return .ok(fav: reply.fav, list: reply.list)
        } catch {
            return .failed
        }
    }
}
