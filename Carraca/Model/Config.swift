import Foundation

// MARK: - Configuración

enum AppConfig {
    /// Panel propio (config.json, Seguir viendo, Deportes). El mismo que usa la app Android.
    static let panel = "https://carracaservice.duckdns.org"
    static var configURL: URL { URL(string: panel + "/config.json")! }
    static var resumeURL: URL { URL(string: panel + "/resume.php")! }
    /// Agenda de deportes del día (texto plano que genera el panel; la pestaña Eventos la pinta en nativo).
    static var sportsURL: URL { URL(string: panel + "/deportes.txt")! }

    static var build: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    static var version: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "" }
}

/// config.json del panel.
struct RemoteConfig: Decodable {
    var baseURL: String?
    var baseURL2: String?
    var iosVersionCode: Int?
    var iosInstallURL: String?

    enum CodingKeys: String, CodingKey { case base_url, base_url_2, ios_version_code, ios_install_url }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        baseURL = c.flexString(.base_url)
        baseURL2 = c.flexString(.base_url_2)
        iosVersionCode = c.flexInt(.ios_version_code)
        iosInstallURL = c.flexString(.ios_install_url)
    }

    /// Servidores Carraca en orden de preferencia.
    var servers: [String] {
        [baseURL, baseURL2].compactMap { $0 }.map(ServerURL.normalize).filter { !$0.isEmpty }
    }
}

/// Servidores Carraca: no van escritos en la app (cambian si se migra el VPS). Se aprenden de
/// config.json y se recuerdan todos los que se han visto, así una cuenta con la dirección vieja
/// se reconoce y se actualiza sola a la nueva.
enum CarracaServers {
    private static let hostsKey = "carraca.known.hosts"
    private static let baseKey = "carraca.known.base"

    /// Hosts conocidos (el del panel siempre).
    static var hosts: Set<String> {
        var h = Set(UserDefaults.standard.stringArray(forKey: hostsKey) ?? [])
        if let p = URL(string: AppConfig.panel)?.host?.lowercased() { h.insert(p) }
        return h
    }

    /// Último servidor que dio config.json (respaldo si config.json no responde).
    static var lastBase: String? { UserDefaults.standard.string(forKey: baseKey) }

    static func remember(_ cfg: RemoteConfig) {
        let servers = cfg.servers
        guard let first = servers.first else { return }
        var h = Set(UserDefaults.standard.stringArray(forKey: hostsKey) ?? [])
        for s in servers { if let host = URL(string: s)?.host?.lowercased() { h.insert(host) } }
        UserDefaults.standard.set(Array(h), forKey: hostsKey)
        UserDefaults.standard.set(first, forKey: baseKey)
    }

    static func isCarraca(_ server: String) -> Bool {
        guard let h = URL(string: server)?.host?.lowercased() else { return false }
        return hosts.contains(h)
    }
}

enum ServerURL {
    /// "midominio.com:8080/" -> "http://midominio.com:8080"
    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "" }
        let low = s.lowercased()
        if !low.hasPrefix("http://") && !low.hasPrefix("https://") { s = "http://" + s }
        for suffix in ["/player_api.php", "/get.php"] where s.hasSuffix(suffix) {
            s.removeLast(suffix.count)
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}
