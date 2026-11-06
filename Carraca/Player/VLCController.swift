import SwiftUI
import MobileVLCKit

struct Track: Identifiable, Hashable {
    let id: Int32
    let name: String
}

/// Tiempo y duración del vídeo, aparte del controlador: cambian varias veces por segundo y así
/// solo se repinta la barra de progreso, no todo el reproductor.
final class PlaybackClock: ObservableObject {
    @Published var timeMs = 0
    @Published var lengthMs = 0
}

/// ¿Hay un reproductor a pantalla completa? Lo de detrás (carrusel de portada) se queda quieto.
@MainActor
final class PlayerPresence: ObservableObject {
    static let shared = PlayerPresence()
    @Published var open = false
}

/// Envoltorio del motor VLC (reproduce TS, MKV, AVI…).
final class VLCController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    let clock = PlaybackClock()

    @Published var playing = false
    @Published var buffering = true
    var timeMs: Int {
        get { clock.timeMs }
        set { if clock.timeMs != newValue { clock.timeMs = newValue } }
    }
    var lengthMs: Int {
        get { clock.lengthMs }
        set { if clock.lengthMs != newValue { clock.lengthMs = newValue } }
    }
    @Published var failed = false
    @Published var ended = false
    /// Por qué no se ha podido reproducir (se pregunta una vez al servidor, al rendirse).
    enum FailReason { case checking, generic, busy, blocked, missing, server, offline, file }
    @Published var failReason = FailReason.generic

    /// Formato de imagen.
    enum AspectMode: String, CaseIterable {
        case fit, fill, wide, classic
        var title: String {
            switch self {
            case .fit: return "Ajustar (original)"
            case .fill: return "Llenar la pantalla"
            case .wide: return "16:9"
            case .classic: return "4:3"
            }
        }
    }
    @Published var aspect = AspectMode.fit { didSet { applyAspect() } }
    /// Sincronización (ms; positivo = más tarde).
    @Published var subtitleDelayMs = 0 { didSet { player.currentVideoSubTitleDelay = subtitleDelayMs * 1000 } }
    @Published var audioDelayMs = 0 { didSet { player.currentAudioPlaybackDelay = audioDelayMs * 1000 } }
    /// Velocidad (pelis y series).
    @Published var rate: Float = 1 { didSet { player.rate = rate } }
    /// Idioma/subtítulos preferidos: se aplican una vez por vídeo, al empezar.
    private var prefsApplied = false

    private var url: URL?
    private var live = false
    private var retries = 0
    private var muted = false
    /// true tras halt(): los reintentos pendientes ya no deben arrancar nada.
    private var halted = false
    /// Salto en curso: a dónde se ha pedido ir (VLC tarda un momento en confirmar la nueva posición).
    private var seekTarget: Int?
    private var seekStarted = Date.distantPast
    /// Vigilante de atascos: VLC a veces se queda "cargando" sin dar error (imagen congelada).
    private var watchdog: Timer?
    private var lastProgress = Date()
    private var lastSeenTime = -1
    private var lastStallRestart = Date.distantPast
    private var stallRestarts = 0

    override init() {
        super.init()
        player.delegate = self
    }

    func start(url: URL, startMs: Int, live: Bool, muted: Bool = false) {
        if url != self.url {
            lastStallRestart = .distantPast
            stallRestarts = 0
        }
        self.url = url
        self.live = live
        self.muted = muted
        halted = false
        seekTarget = nil
        failed = false
        failReason = .generic
        ended = false
        prefsApplied = false
        buffering = true
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=\(live ? (muted ? 1500 : 2500) : 4000)")
        if muted { media.addOption(":no-audio") }
        if startMs > 0 { media.addOption(":start-time=\(Double(startMs) / 1000.0)") }
        player.media = media
        player.play()
        lastProgress = Date()
        lastSeenTime = -1
        startWatchdog()
    }

    /// Si el vídeo no avanza (15 s en directo, 25 s en pelis y series) sin estar en pausa, se vuelve
    /// a abrir solo, como mucho una vez por minuto (el proveedor banea las ráfagas de conexiones).
    /// Tras 3 intentos seguidos sin que avance, se da por fallido y se explica por qué.
    /// No vigila la vista previa (sin sonido) para no abrir conexiones de más.
    private func startWatchdog() {
        watchdog?.invalidate()
        guard !muted else { watchdog = nil; return }
        let t = Timer(timeInterval: 3, repeats: true) { [weak self] _ in self?.checkStall() }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private func checkStall() {
        guard !halted, !failed, !ended, let url else { return }
        if player.state == .paused { lastProgress = Date(); return }
        let stalled = Date().timeIntervalSince(lastProgress)
        guard stalled > (live ? 15 : 25), Date().timeIntervalSince(lastStallRestart) > 60 else { return }
        if stallRestarts >= 3 {
            failed = true
            buffering = false
            playing = false
            watchdog?.invalidate()
            diagnose(url)
            return
        }
        stallRestarts += 1
        lastStallRestart = Date()
        start(url: url, startMs: live ? 0 : (seekTarget ?? timeMs), live: live, muted: muted)
    }

    func restart() {
        retries = 0
        guard let url else { return }
        start(url: url, startMs: live ? 0 : timeMs, live: live)
    }

    func toggle() {
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func seek(toFraction f: Double) {
        let frac = max(0, min(1, f))
        if lengthMs > 0 {
            seek(toMs: Int(Double(lengthMs) * frac))
            return
        }
        player.position = Float(frac)
    }

    func jump(_ seconds: Int32) {
        seek(toMs: (seekTarget ?? timeMs) + Int(seconds) * 1000)
    }

    /// Salto a un tiempo absoluto. Varios saltos seguidos se encadenan desde el último destino
    /// pedido, y si hay un corte mientras tanto se retoma desde ahí, no desde el sitio viejo.
    private func seek(toMs requested: Int) {
        let target = max(0, lengthMs > 0 ? min(requested, lengthMs - 2000) : requested)
        guard target != (seekTarget ?? timeMs) else { return }
        seekTarget = target
        seekStarted = Date()
        timeMs = target
        buffering = true
        player.time = VLCTime(int: Int32(clamping: target))
    }

    func stop() {
        watchdog?.invalidate()
        watchdog = nil
        player.delegate = nil
        player.stop()
    }

    deinit { watchdog?.invalidate() }

    /// Para la reproducción pero deja el controlador listo para otro start() (vista previa).
    func halt() {
        watchdog?.invalidate()
        watchdog = nil
        halted = true
        retries = 0
        player.stop()
        playing = false
        buffering = false
        failed = false
    }

    // MARK: Pistas de audio y subtítulos

    var audioTracks: [Track] { tracks(player.audioTrackIndexes, player.audioTrackNames) }
    var subtitleTracks: [Track] { tracks(player.videoSubTitlesIndexes, player.videoSubTitlesNames) }
    var currentAudio: Int32 { player.currentAudioTrackIndex }
    var currentSubtitle: Int32 { player.currentVideoSubTitleIndex }

    func setAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        objectWillChange.send()
    }

    func setSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        objectWillChange.send()
    }

    /// Ajustes > Reproducción: audio y subtítulos preferidos.
    private func applyPreferredTracks() {
        let audioPref = PlaybackPrefs.audio
        if !audioPref.isEmpty, let t = audioTracks.first(where: { $0.id >= 0 && PlaybackPrefs.matches($0.name, audioPref) }) {
            setAudio(t.id)
        }
        switch PlaybackPrefs.subs {
        case "": break
        case "off": setSubtitle(-1)
        case let pref:
            if let t = subtitleTracks.first(where: { $0.id >= 0 && PlaybackPrefs.matches($0.name, pref) }) {
                setSubtitle(t.id)
            } else if pref == "forzados" {
                setSubtitle(-1)
            }
        }
    }

    /// Guarda las cadenas C que pide VLC (no las libera mientras las usa).
    private var aspectCString: UnsafeMutablePointer<CChar>?
    private var cropCString: UnsafeMutablePointer<CChar>?

    private func applyAspect() {
        let oldAspect = aspectCString, oldCrop = cropCString
        aspectCString = nil
        cropCString = nil
        switch aspect {
        case .fit:
            break
        case .fill:
            // recorta el vídeo a la forma de la pantalla (sin bandas negras)
            let b = UIScreen.main.bounds
            let w = Int(max(b.width, b.height)), h = Int(min(b.width, b.height))
            cropCString = strdup("\(w):\(h)")
        case .wide:
            aspectCString = strdup("16:9")
        case .classic:
            aspectCString = strdup("4:3")
        }
        player.videoAspectRatio = aspectCString
        player.videoCropGeometry = cropCString
        free(oldAspect)
        free(oldCrop)
    }

    private func tracks(_ indexes: [Any]?, _ names: [Any]?) -> [Track] {
        let ids = (indexes ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        let titles = (names ?? []).map { "\($0)" }
        return zip(ids, titles).map { Track(id: $0, name: $1) }
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch self.player.state {
            case .opening:
                self.buffering = true
            case .buffering:
                if !self.player.isPlaying { self.buffering = true }
            case .playing:
                self.buffering = false
                self.playing = true
                self.retries = 0
                if !self.prefsApplied, !self.muted {
                    self.prefsApplied = true
                    // las pistas aparecen un instante después de empezar
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.applyPreferredTracks() }
                    self.applyAspect()
                    if self.subtitleDelayMs != 0 { self.player.currentVideoSubTitleDelay = self.subtitleDelayMs * 1000 }
                    if self.audioDelayMs != 0 { self.player.currentAudioPlaybackDelay = self.audioDelayMs * 1000 }
                }
                if self.rate != 1 && self.player.rate != self.rate { self.player.rate = self.rate }
            case .paused:
                self.playing = false
            case .error:
                self.handleError()
            case .ended:
                if self.live { self.handleError() } else { self.ended = true }
            case .stopped:
                self.playing = false
            default:
                break
            }
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let t = Int(self.player.time.intValue)
            if t != self.lastSeenTime {
                // avanza: el vigilante se queda tranquilo
                if self.lastSeenTime >= 0 { self.stallRestarts = 0 }
                self.lastSeenTime = t
                self.lastProgress = Date()
            }
            if let target = self.seekTarget {
                // Hasta que VLC llega al destino, sus tiempos son del sitio viejo: no los enseñamos.
                if abs(t - target) > 15_000 && Date().timeIntervalSince(self.seekStarted) < 20 { return }
                self.seekTarget = nil
            }
            // VLC avisa ~4 veces por segundo; la barra no necesita tanto
            if abs(t - self.timeMs) >= 450 || t < self.timeMs { self.timeMs = t }
            if let len = self.player.media?.length.intValue, len > 0 { self.lengthMs = Int(len) }
            if self.buffering { self.buffering = false }
            if !self.playing && self.player.isPlaying { self.playing = true }
        }
    }

    /// Como mucho 3 reintentos y con pausa creciente: el proveedor banea las ráfagas.
    private func handleError() {
        if halted { return }
        guard retries < 3, let url else {
            failed = true
            buffering = false
            playing = false
            if let url { diagnose(url) }
            return
        }
        retries += 1
        buffering = true
        let resumeAt = live ? 0 : (seekTarget ?? timeMs)
        let isLive = live
        let isMuted = muted
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(3 * retries)) { [weak self] in
            guard let self, !self.halted, self.url == url else { return }
            self.start(url: url, startMs: resumeAt, live: isLive, muted: isMuted)
        }
    }
}

extension VLCController {
    /// Una sola petición (solo cabeceras, se corta en cuanto responde) para saber qué ha pasado:
    /// cuenta en uso en otro sitio, IP bloqueada, contenido retirado, servidor caído o sin internet.
    func diagnose(_ url: URL) {
        if url.isFileURL { failReason = .file; return }
        failReason = .checking
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.setValue("CarracaiOS/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
        Task { @MainActor [weak self] in
            var reason = FailReason.generic
            do {
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                bytes.task.cancel()
                switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
                case 401, 403, 407, 423, 451: reason = .blocked
                case 429, 456...462, 509: reason = .busy
                case 404, 410, 551: reason = .missing
                case 500...599: reason = .server
                default: reason = .generic
                }
            } catch let e as URLError where [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(e.code) {
                reason = .offline
            } catch {
                reason = .generic
            }
            self?.failReason = reason
        }
    }
}

struct VLCVideoView: UIViewRepresentable {
    let controller: VLCController

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        // Las vistas de VLC no deben quedarse con los toques: si no, los controles
        // de SwiftUI nunca reciben el "tap" y no se puede salir del reproductor.
        v.isUserInteractionEnabled = false
        controller.player.drawable = v
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Preferencias de reproducción (Ajustes > Reproducción).
enum PlaybackPrefs {
    static let audioKey = "carraca.pref.audio"          // "" | castellano | latino | ingles
    static let subsKey = "carraca.pref.subs"            // "" | off | castellano | ingles | forzados
    static let autoNextKey = "carraca.pref.autonext"    // Bool (por defecto true)

    static var audio: String { UserDefaults.standard.string(forKey: audioKey) ?? "" }
    static var subs: String { UserDefaults.standard.string(forKey: subsKey) ?? "" }
    static var autoNext: Bool { UserDefaults.standard.object(forKey: autoNextKey) as? Bool ?? true }

    /// ¿El nombre de la pista encaja con la preferencia?
    static func matches(_ name: String, _ pref: String) -> Bool {
        let n = name.lowercased()
        switch pref {
        case "castellano":
            if ["latino", "latam", "lat)", "mexic"].contains(where: { n.contains($0) }) { return false }
            return ["castellano", "españa", "spain", "spa", "esp", "español", "spanish"].contains(where: { n.contains($0) })
        case "latino":
            return ["latino", "latam", "lat", "mexic"].contains(where: { n.contains($0) })
        case "ingles":
            return ["eng", "english", "inglés", "ingles"].contains(where: { n.contains($0) })
        case "forzados":
            return ["forz", "forced"].contains(where: { n.contains($0) })
        default:
            return false
        }
    }
}
