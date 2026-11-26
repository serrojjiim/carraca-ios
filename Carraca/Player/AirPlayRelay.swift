import SwiftUI
import UIKit
import AVFoundation

/// Qué emitir por el relay del servidor (cast.php): una cuenta Xtream del servidor Carraca.
struct CastSource: Equatable {
    enum Kind: String { case live, movie, series }
    let kind: Kind
    /// Id numérico del stream, película o capítulo.
    let id: Int
    /// Extensión del archivo (mkv, mp4…). En directo no hace falta.
    let ext: String?
}

/// Llamadas a cast.php. Usuario y contraseña van solo en el cuerpo JSON (nunca en la URL ni en logs).
enum CastAPI {
    static let endpoint = URL(string: "https://carracaservice.duckdns.org/cast.php")!

    static func post(_ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var req = URLRequest(url: endpoint, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("CarracaiOS/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        return obj
    }

    /// Libera la conexión del proveedor. Los errores se ignoran (el servidor corta solo sin latidos).
    static func stop(_ sid: String) async {
        _ = try? await post(["act": "stop", "sid": sid], timeout: 10)
    }
}

/// Emisión AirPlay con relay: el servidor abre la única conexión con el proveedor y sirve HLS;
/// el teléfono solo reproduce ese HLS con AVPlayer en la salida AirPlay y VLC se queda parado.
/// Un único objeto compartido: solo puede haber un reproductor abierto a la vez.
@MainActor
final class AirPlayCast: ObservableObject {
    static let shared = AirPlayCast()

    enum Phase: Equatable {
        case idle
        case preparing
        case casting
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// AVPlayer está reproduciendo.
    @Published private(set) var playing = false
    /// El vídeo sale ya por la TV (isExternalPlaybackActive).
    @Published private(set) var videoOnTV = false
    /// Pantalla de AVPlayer (nil si no hay emisión). Solo lo lee la capa oculta de PlayerView.
    @Published private(set) var player: AVPlayer?
    /// Posición absoluta en segundos (VOD: desde la peli o capítulo; directo: 0). No publicada: no repinta.
    private(set) var positionSec: Double = 0
    /// Lo que se emite ahora (para reintentar, saltar y cambiar de canal).
    private(set) var source: CastSource?

    private var user = ""
    private var pass = ""
    private var baseSec: Double = 0
    private var sid: String?
    /// Cada arranque o parada sube el número: lo que llega de una generación vieja se descarta.
    private var generation = 0
    private var startTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var pendingSec: Double?
    private var timeToken: Any?
    private var rateObs: NSKeyValueObservation?
    private var extObs: NSKeyValueObservation?

    private init() {}

    /// Salida de audio/vídeo AirPlay ahora mismo (Apple TV, tele o altavoz).
    static var routeIsAirPlay: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
    }

    static var routeName: String? {
        AVAudioSession.sharedInstance().currentRoute.outputs.first { $0.portType == .airPlay }?.portName
    }

    /// Empieza a emitir `source` desde `fromSec` (solo VOD). Espera `wait` segundos antes de pedir el
    /// arranque, para que VLC suelte la conexión. Si había una emisión, la para antes.
    func begin(_ source: CastSource, user: String, pass: String, fromSec: Double, wait: Double) {
        generation += 1
        let gen = generation
        let previous = startTask
        let oldSid = sid
        debounce?.cancel()
        debounce = nil
        pingTask?.cancel()
        pingTask = nil
        teardownPlayer()
        sid = nil
        pendingSec = nil
        self.source = source
        self.user = user
        self.pass = pass
        baseSec = source.kind == .live ? 0 : max(0, fromSec)
        positionSec = baseSec
        phase = .preparing
        let body = makeBody(source, fromSec: baseSec, user: user, pass: pass)
        startTask = Task { @MainActor [weak self] in
            await previous?.value
            if let oldSid { await CastAPI.stop(oldSid) }
            guard let self, gen == self.generation else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, wait) * 1_000_000_000))
            guard gen == self.generation else { return }
            // VLC puede haber cambiado la sesión de audio al pararse: se deja como en la app.
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            await self.request(gen: gen, body: body, attempt: 0)
        }
    }

    /// Reintenta lo último que se emitía (desde donde se quedó).
    func retry() {
        guard let source else { return }
        begin(source, user: user, pass: pass, fromSec: positionSec, wait: 1)
    }

    /// VOD: salta `seconds`. Un salto nuevo es un arranque nuevo en el servidor, así que varios
    /// saltos seguidos se agrupan y dan un solo arranque (el servidor admite 6 por minuto).
    func jump(by seconds: Double) {
        guard let source, source.kind != .live else { return }
        let target = max(0, (pendingSec ?? positionSec) + seconds)
        schedule(source, fromSec: target)
    }

    /// Directo: otro canal (un solo arranque aunque se cambie varias veces seguidas).
    func zap(to source: CastSource) {
        schedule(source, fromSec: 0)
    }

    private func schedule(_ source: CastSource, fromSec: Double) {
        debounce?.cancel()
        pendingSec = fromSec
        positionSec = fromSec
        let user = self.user, pass = self.pass
        debounce = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.begin(source, user: user, pass: pass, fromSec: fromSec, wait: 0.5)
        }
    }

    func togglePlay() {
        setPlaying(!playing)
    }

    func setPlaying(_ on: Bool) {
        guard let player else { return }
        if on { player.play() } else { player.pause() }
    }

    /// Para la emisión y espera a que el servidor confirme que ha soltado la conexión del proveedor.
    func stop() async {
        generation += 1
        debounce?.cancel()
        debounce = nil
        pingTask?.cancel()
        pingTask = nil
        teardownPlayer()
        phase = .idle
        let previous = startTask
        startTask = nil
        await previous?.value
        if let s = sid {
            sid = nil
            await CastAPI.stop(s)
        }
    }

    // MARK: Peticiones y latido

    private func makeBody(_ source: CastSource, fromSec: Double, user: String, pass: String) -> [String: Any] {
        var b: [String: Any] = ["act": "start", "user": user, "pass": pass,
                                "kind": source.kind.rawValue, "id": source.id, "fmt": "fmp4"]
        if let ext = source.ext { b["ext"] = ext }
        if source.kind != .live { b["start"] = Int(fromSec) }
        return b
    }

    private func request(gen: Int, body: [String: Any], attempt: Int) async {
        guard gen == generation else { return }
        let reply: [String: Any]
        do {
            reply = try await CastAPI.post(body, timeout: 40)
        } catch {
            if gen == generation { fail("No se ha podido conectar con el servidor de emisión.") }
            return
        }
        let ok = reply["ok"] as? Bool ?? false
        if gen != generation {
            // llegó tarde (se paró o se cambió de canal mientras tanto): si arrancó algo, se para
            if ok, let s = reply["sid"] as? String { await CastAPI.stop(s) }
            return
        }
        guard ok, let s = reply["sid"] as? String, let u = reply["url"] as? String, let url = URL(string: u) else {
            // "proveedor": un solo reintento, a los 5 s
            if (reply["error"] as? String) == "proveedor", attempt == 0 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await request(gen: gen, body: body, attempt: 1)
                return
            }
            fail(reply["msg"] as? String ?? "No se ha podido iniciar la emisión.")
            return
        }
        play(sid: s, url: url)
    }

    private func play(sid s: String, url: URL) {
        sid = s
        let p = AVPlayer(playerItem: AVPlayerItem(url: url))
        p.allowsExternalPlayback = true
        p.usesExternalPlaybackWhileExternalScreenIsActive = true
        player = p
        timeToken = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
                                              queue: .main) { [weak self] time in
            let sec = time.seconds
            Task { @MainActor in self?.tick(sec) }
        }
        rateObs = p.observe(\.rate, options: [.initial, .new]) { [weak self] obj, _ in
            let on = obj.rate > 0
            Task { @MainActor in self?.playing = on }
        }
        extObs = p.observe(\.isExternalPlaybackActive, options: [.initial, .new]) { [weak self] obj, _ in
            let v = obj.isExternalPlaybackActive
            Task { @MainActor in self?.videoOnTV = v }
        }
        phase = .casting
        p.play()
        startPing(sid: s)
    }

    private func tick(_ sec: Double) {
        guard sec.isFinite, phase == .casting else { return }
        positionSec = baseSec + sec
    }

    /// Latido cada 15 s (el servidor corta a los 60 s sin él). Dos fallos de red seguidos = corte.
    private func startPing(sid s: String) {
        pingTask?.cancel()
        pingTask = Task { @MainActor [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled, let self, self.sid == s else { return }
                let reply = try? await CastAPI.post(["act": "ping", "sid": s], timeout: 10)
                guard !Task.isCancelled, self.sid == s else { return }
                if let reply {
                    misses = 0
                    if (reply["ok"] as? Bool ?? false) && (reply["alive"] as? Bool ?? false) { continue }
                    self.fail("La emisión se ha cortado.")
                    return
                }
                misses += 1
                if misses >= 2 {
                    self.fail("Se ha perdido la conexión con el servidor de emisión.")
                    return
                }
            }
        }
    }

    /// Error: se para el latido y el AVPlayer, y se para la emisión en el servidor (sin esperar).
    private func fail(_ message: String) {
        pingTask?.cancel()
        pingTask = nil
        let s = sid
        sid = nil
        teardownPlayer()
        phase = .failed(message)
        if let s { Task { await CastAPI.stop(s) } }
    }

    private func teardownPlayer() {
        if let t = timeToken { player?.removeTimeObserver(t) }
        timeToken = nil
        rateObs?.invalidate()
        rateObs = nil
        extObs?.invalidate()
        extObs = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playing = false
        videoOnTV = false
    }
}

/// Capa de AVPlayer en un UIView sin verse: el vídeo sale por la TV (AirPlay), en el teléfono no se enseña.
struct CastPlayerHost: UIViewRepresentable {
    let player: AVPlayer?

    func makeUIView(context: Context) -> CastLayerView {
        let v = CastLayerView()
        v.isUserInteractionEnabled = false
        v.alpha = 0
        return v
    }

    func updateUIView(_ uiView: CastLayerView, context: Context) {
        uiView.playerLayer.player = player
    }
}

final class CastLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
