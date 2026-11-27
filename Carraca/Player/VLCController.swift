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

/// Cómo ha terminado una sesión de reproducción (telemetría).
fileprivate enum PlayOutcome { case ok, stop, err }

/// Datos de una sesión de reproducción para el resumen anónimo `play` (ver tools/telemetria/SCHEMA.md).
fileprivate struct PlayTelemetry {
    let kind: String
    let sid: Int?
    let startedAt = Date()
    var firstFrameAt: Date?
    var stalls = 0
    var stallMs = 0
    var stallStart: Date?
    var wd = 0
    var retries = 0
    var failed = false
    var err = "checking"
    var http = 0
    // Ampliación v2 (diagnóstico): solo se rellenan si VLC/el sistema lo dan; si no, se omiten en el envío.
    var cont: String?
    var vc: String?
    var w: Int?
    var h: Int?
    var fps: Int?
    var vbr: Int?
    var memMin: Int?
    var frzStart: Date?     // inicio de un episodio de congelación abierto
    var frzMs = 0
    var frzN = 0

    init(kind: String, sid: Int?) {
        self.kind = kind
        self.sid = sid
    }
}

/// Envoltorio del motor VLC (reproduce TS, MKV, AVI…).
final class VLCController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    let clock = PlaybackClock()
    /// Vista de este reproductor en el teléfono (la pantalla externa la gestiona ExternalDisplay).
    weak var phoneVideoView: UIView?

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
    /// Última vez que se programó un reintento (los reintentos solo se ponen a 0 tras 30 s de imagen estable).
    private var lastRetryAt = Date.distantPast
    /// true mientras se espera para preguntar al servidor por qué ha fallado (antes del primer reintento).
    private var probing = false
    private var muted = false
    /// true tras halt(): los reintentos pendientes ya no deben arrancar nada.
    private var halted = false
    /// true mientras la emisión AirPlay (relay) tiene la conexión: ningún método de aquí la reabre.
    private var suspended = false
    /// Salto en curso: a dónde se ha pedido ir (VLC tarda un momento en confirmar la nueva posición).
    private var seekTarget: Int?
    private var seekStarted = Date.distantPast
    /// Vigilante de atascos: VLC a veces se queda "cargando" sin dar error (imagen congelada).
    private var watchdog: Timer?
    private var lastProgress = Date()
    private var lastSeenTime = -1
    private var lastStallRestart = Date.distantPast
    private var stallRestarts = 0
    /// Sesión de telemetría en curso (nil para vista previa, archivos locales y tras cerrar).
    private var tele: PlayTelemetry?

    override init() {
        super.init()
        player.delegate = self
    }

    func start(url: URL, startMs: Int, live: Bool, muted: Bool = false) {
        // con AirPlay (relay) el servidor tiene la única conexión: aquí no se abre nada
        guard !suspended else { return }
        // un episodio de congelación abierto termina aquí (reinicio del vigilante o del motor)
        telemetryFreezeEnd()
        if url != self.url {
            lastStallRestart = .distantPast
            stallRestarts = 0
        }
        // telemetría: una sesión por canal/película (los reintentos del mismo canal no abren otra)
        if !muted, !url.isFileURL, tele == nil || url != self.url {
            telemetryFinish(.ok)
            telemetryBegin(url: url, live: live)
        }
        self.url = url
        self.live = live
        self.muted = muted
        halted = false
        seekTarget = nil
        probing = false
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
        telemetryWatch()
        if player.state == .paused { lastProgress = Date(); return }
        // reproduciendo con normalidad desde hace un rato: los reintentos vuelven a empezar
        if retries > 0, Date().timeIntervalSince(lastRetryAt) > 30, Date().timeIntervalSince(lastProgress) < 6 { retries = 0 }
        let stalled = Date().timeIntervalSince(lastProgress)
        guard stalled > (live ? 15 : 25), Date().timeIntervalSince(lastStallRestart) > 60 else { return }
        tele?.wd += 1
        if stallRestarts >= 3 {
            telemetryMarkFailed()
            failed = true
            buffering = false
            playing = false
            watchdog?.invalidate()
            player.stop()          // se suelta la conexión: el diagnóstico no debe ser una segunda
            diagnose(url)
            return
        }
        stallRestarts += 1
        lastStallRestart = Date()
        start(url: url, startMs: live ? 0 : (seekTarget ?? timeMs), live: live, muted: muted)
    }

    func restart() {
        guard !suspended else { return }
        retries = 0
        guard let url else { return }
        start(url: url, startMs: live ? 0 : timeMs, live: live)
    }

    func toggle() {
        guard !suspended else { return }
        if player.isPlaying { player.pause() } else { player.play() }
    }

    func play() {
        guard !suspended else { return }
        player.play()
    }

    func pause() {
        guard !suspended else { return }
        player.pause()
    }

    /// AirPlay con relay: VLC se para y se suelta la conexión. Nada vuelve a conectar hasta resume().
    func suspend() {
        halt()
        suspended = true
    }

    /// Fin de la emisión AirPlay: la siguiente start() vuelve a abrir la conexión.
    func resume() {
        suspended = false
    }

    func seek(toFraction f: Double) {
        guard !suspended else { return }
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
        guard !suspended else { return }
        let target = max(0, lengthMs > 0 ? min(requested, lengthMs - 2000) : requested)
        guard target != (seekTarget ?? timeMs) else { return }
        seekTarget = target
        seekStarted = Date()
        timeMs = target
        buffering = true
        player.time = VLCTime(int: Int32(clamping: target))
    }

    func stop() {
        telemetryFinish(.stop)
        halted = true      // ningún reintento pendiente puede reabrir el canal después de cerrar
        watchdog?.invalidate()
        watchdog = nil
        player.delegate = nil
        player.stop()
    }

    deinit { watchdog?.invalidate() }

    /// Pone el vídeo en esta vista (la del teléfono o la de la pantalla externa). Con nil no cambia nada.
    /// VLC admite cambiar la vista mientras reproduce; la reproducción no se reinicia.
    func showVideo(in view: UIView?) {
        guard let view else { return }
        player.drawable = view
    }

    /// Para la reproducción pero deja el controlador listo para otro start() (vista previa).
    func halt() {
        telemetryFinish(.stop)
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
                if !self.player.isPlaying { self.buffering = true; self.telemetryStallBegin() }
            case .playing:
                self.buffering = false
                self.telemetryStallEnd()
                self.telemetryFirstFrame()
                self.playing = true
                // (los reintentos NO se ponen a 0 aquí: un canal que arranca y se cae otra vez reintentaría sin tope)
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
                if self.live { self.handleError() } else { self.ended = true; self.telemetryFinish(.ok) }
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
            // con el flujo cortado (fallo o comprobación en curso) VLC da 0: se conserva el último punto bueno
            if self.failed || self.probing { return }
            let t = Int(self.player.time.intValue)
            if t != self.lastSeenTime {
                // avanza: el vigilante se queda tranquilo
                if self.lastSeenTime >= 0 { self.stallRestarts = 0 }
                self.lastSeenTime = t
                self.lastProgress = Date()
                self.telemetryStallEnd()
                self.telemetryFreezeEnd()
                self.telemetryFirstFrame()
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
    /// Antes del primero se suelta la conexión y se pregunta UNA vez al servidor por qué ha fallado: si es
    /// "cuenta en uso", bloqueo o retirado, no se insiste (otro aparato tiene la conexión y se pelearían).
    private func handleError() {
        if halted { return }
        // vista previa (sin sonido): nunca reintenta ni pregunta; se queda en "no disponible"
        if muted {
            player.stop()
            failed = true
            buffering = false
            playing = false
            return
        }
        guard retries < 3, let url else {
            telemetryMarkFailed()
            failed = true
            buffering = false
            playing = false
            if let url { player.stop(); diagnose(url) }
            return
        }
        let resumeAt = live ? 0 : (seekTarget ?? timeMs)
        let isLive = live
        if retries == 0, !url.isFileURL {
            if probing { return }
            probing = true
            buffering = true
            player.stop()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                self.probing = false
                guard !self.halted, self.url == url else { return }
                let probed = await VLCController.probe(url)
                guard !self.halted, self.url == url else { return }
                let reason = probed.reason
                if reason == .blocked || reason == .busy || reason == .missing {
                    self.failReason = reason
                    self.failed = true
                    self.buffering = false
                    self.playing = false
                    self.telemetryFailed(reason, http: probed.http)
                    return
                }
                self.retries = 1
                self.tele?.retries += 1
                self.lastRetryAt = Date()
                self.start(url: url, startMs: resumeAt, live: isLive, muted: false)
            }
            return
        }
        retries += 1
        tele?.retries += 1
        lastRetryAt = Date()
        buffering = true
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
    /// Devuelve el motivo y, si lo hay, el código HTTP (para la telemetría; nunca el texto del error).
    static func probe(_ url: URL) async -> (reason: FailReason, http: Int) {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.setValue("CarracaiOS/\(AppConfig.version)", forHTTPHeaderField: "User-Agent")
        do {
            let (bytes, resp) = try await URLSession.shared.bytes(for: req)
            bytes.task.cancel()
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 401, 403, 407, 423, 451: return (.blocked, code)
            case 429, 456...462, 509: return (.busy, code)
            case 404, 410, 551: return (.missing, code)
            case 500...599: return (.server, code)
            default: return (.generic, code)
            }
        } catch let e as URLError where [URLError.Code.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(e.code) {
            return (.offline, 0)
        } catch {
            return (.generic, 0)
        }
    }

    /// Diagnóstico al rendirse (el motor ya está parado). Espera un momento a que el proveedor suelte la
    /// conexión anterior: si no, la respuesta sería un falso "cuenta en uso".
    func diagnose(_ url: URL) {
        if url.isFileURL { failReason = .file; return }
        failReason = .checking
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, !self.halted else { return }
            let probed = await VLCController.probe(url)
            self.failReason = probed.reason
            self.telemetryFailed(probed.reason, http: probed.http)
        }
    }

    // MARK: Telemetría anónima (un resumen `play` por sesión; sin URLs ni nombres)

    /// Abre la sesión: el tipo sale de la ruta de Xtream y el id es solo el número del stream.
    private func telemetryBegin(url: URL, live: Bool) {
        let kind = live ? "live" : (url.path.contains("/series/") ? "series" : "vod")
        let sid = Int(url.deletingPathExtension().lastPathComponent)
        tele = PlayTelemetry(kind: kind, sid: sid)
        tele?.cont = VLCController.containerKind(url)
        Telemetry.shared.setPlaybackActive(true)
    }

    /// Contenedor/protocolo deducido de la extensión de la URL (la URL en sí nunca se envía).
    /// Sin extensión (típico en directo Xtream) no se sabe: nil.
    private static func containerKind(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return nil }
        switch ext {
        case "ts": return "ts"
        case "m3u8": return "hls"
        case "mkv": return "mkv"
        case "mp4", "m4v": return "mp4"
        case "mpd": return "dash"
        default: return "other"
        }
    }

    /// Cierra la sesión. Menos de 5 s sin fallo cuenta como zapping; el resto emite `play`.
    private func telemetryFinish(_ outcome: PlayOutcome) {
        telemetryFreezeEnd()
        guard var t = tele else { return }
        tele = nil
        Telemetry.shared.setPlaybackActive(false)
        let now = Date()
        if let s = t.stallStart {
            t.stallStart = nil
            let ms = Int(now.timeIntervalSince(s) * 1000)
            if ms >= 1000 { t.stalls += 1; t.stallMs += ms }
        }
        let out: PlayOutcome = t.failed ? .err : outcome
        if out != .err && now.timeIntervalSince(t.startedAt) < 5 {
            Telemetry.shared.countZap()
            return
        }
        let ttff = t.firstFrameAt.map { Int($0.timeIntervalSince(t.startedAt) * 1000) } ?? -1
        let watch = t.firstFrameAt.map { Int(now.timeIntervalSince($0)) } ?? 0
        let outName = out == .ok ? "ok" : (out == .stop ? "stop" : "err")
        var f: [String: TVal] = [
            "kind": .s(t.kind), "eng": .s("vlc"), "fb": .i(0), "ttff": .i(ttff),
            "stalls": .i(t.stalls), "stall_ms": .i(t.stallMs), "wd": .i(t.wd), "retries": .i(t.retries),
            "out": .s(outName), "err": .s(out == .err ? t.err : "none"),
            "http": .i(t.http), "watch_s": .i(watch)
        ]
        if let sid = t.sid { f["sid"] = .i(sid) }
        // ampliación v2: solo los campos que se han llegado a conocer
        if let c = t.cont { f["cont"] = .s(c) }
        if let v = t.vc, let s = Telemetry.safeText(v) { f["vc"] = .s(s) }
        if let w = t.w, let h = t.h { f["w"] = .i(w); f["h"] = .i(h) }
        if let fps = t.fps { f["fps"] = .i(fps) }
        if let vbr = t.vbr { f["vbr"] = .i(vbr) }
        if let net = Telemetry.netType { f["net"] = .s(net) }
        if let mem = t.memMin { f["mem_mb"] = .i(mem) }
        f["frz_ms"] = .i(t.frzMs)
        f["frz_n"] = .i(t.frzN)
        Telemetry.shared.log("play", f)
    }

    private func telemetryFirstFrame() {
        if tele?.firstFrameAt == nil { tele?.firstFrameAt = Date() }
    }

    /// Tick del vigilante (cada 3 s con reproducción): memoria mínima, datos del vídeo y congelaciones.
    /// Solo observa; no cambia la reproducción ni el vigilante.
    private func telemetryWatch() {
        guard tele != nil else { return }
        if let mb = Telemetry.availableMemoryMB() {
            tele?.memMin = min(tele?.memMin ?? mb, mb)
        }
        telemetryReadTracks()
        // congelación: la posición lleva ≥ 3 s parada estando "reproduciendo" y sin buffering
        let stalledFor = Date().timeIntervalSince(lastProgress)
        let frozen = tele?.firstFrameAt != nil && player.isPlaying && !buffering && seekTarget == nil && stalledFor >= 3
        if frozen {
            if tele?.frzStart == nil { tele?.frzStart = lastProgress }
        } else {
            tele?.frzStart = nil    // no era congelación (pausa, buffering o salto): se descarta
        }
    }

    /// Cierra un episodio de congelación abierto. Cuenta solo si ha durado al menos 3 s.
    private func telemetryFreezeEnd() {
        guard let s = tele?.frzStart else { return }
        tele?.frzStart = nil
        let ms = Int(Date().timeIntervalSince(s) * 1000)
        if ms >= 3000 {
            tele?.frzN += 1
            tele?.frzMs += ms
        }
    }

    /// Códec, resolución, fps y tasa de vídeo, leídos de VLC cuando ya hay imagen (se reintenta en cada tick hasta tenerlos).
    private func telemetryReadTracks() {
        guard let t = tele, t.firstFrameAt != nil, t.w == nil, let media = player.media else { return }
        let infos = (media.tracksInformation as? [[String: Any]]) ?? []
        guard let v = infos.first(where: { $0[VLCMediaTracksInformationVideoWidth] != nil }) else { return }
        let w = (v[VLCMediaTracksInformationVideoWidth] as? NSNumber)?.intValue ?? 0
        let h = (v[VLCMediaTracksInformationVideoHeight] as? NSNumber)?.intValue ?? 0
        guard (1...8192).contains(w), (1...8192).contains(h) else { return }
        tele?.w = w
        tele?.h = h
        if let n = v[VLCMediaTracksInformationCodec] as? NSNumber {
            tele?.vc = VLCController.codecName(fourCC: n.uint32Value)
        }
        let num = (v[VLCMediaTracksInformationFrameRate] as? NSNumber)?.doubleValue ?? 0
        let den = (v[VLCMediaTracksInformationFrameRateDenominator] as? NSNumber)?.doubleValue ?? 0
        if num > 0, den > 0 {
            let fps = Int((num / den).rounded())
            if (1...240).contains(fps) { tele?.fps = fps }
        }
        let kbps = ((v[VLCMediaTracksInformationBitrate] as? NSNumber)?.intValue ?? 0) / 1000
        if (1...400_000).contains(kbps) { tele?.vbr = kbps }
    }

    /// FourCC de VLC a nombre corto ("h264", "hevc"…). Prueba ambos órdenes de bytes; nil si no es conocido.
    private static func codecName(fourCC v: UInt32) -> String? {
        let known: [(code: String, name: String)] = [
            ("avc1", "h264"), ("avc3", "h264"), ("h264", "h264"),
            ("hvc1", "hevc"), ("hev1", "hevc"), ("hevc", "hevc"),
            ("mp2v", "mpeg2"), ("mpg2", "mpeg2"), ("mp4v", "mpeg4"),
            ("vp80", "vp8"), ("vp90", "vp9"), ("av01", "av1")
        ]
        return known.first(where: { v == fourCCValue($0.code, bigEndian: false) || v == fourCCValue($0.code, bigEndian: true) })?.name
    }

    private static func fourCCValue(_ s: String, bigEndian: Bool) -> UInt32 {
        var out: UInt32 = 0
        for (i, b) in s.utf8.prefix(4).enumerated() {
            let shift = bigEndian ? 8 * (3 - i) : 8 * i
            out |= UInt32(b) << UInt32(shift)
        }
        return out
    }

    /// Un corte cuenta desde que VLC para tras el primer fotograma (no el arranque ni un salto de posición).
    private func telemetryStallBegin() {
        guard tele?.firstFrameAt != nil, tele?.stallStart == nil, seekTarget == nil else { return }
        tele?.stallStart = Date()
    }

    private func telemetryStallEnd() {
        guard let s = tele?.stallStart else { return }
        tele?.stallStart = nil
        let ms = Int(Date().timeIntervalSince(s) * 1000)
        if ms >= 1000 { tele?.stalls += 1; tele?.stallMs += ms }
    }

    /// Se marca el fallo; el motivo llega cuando el diagnóstico contesta (o al cerrar la sesión).
    private func telemetryMarkFailed() {
        tele?.failed = true
    }

    private func telemetryFailed(_ reason: FailReason, http: Int) {
        guard tele != nil else { return }
        tele?.failed = true
        tele?.err = VLCController.telemetryErr(reason)
        tele?.http = http
        telemetryFinish(.err)
    }

    private static func telemetryErr(_ r: FailReason) -> String {
        switch r {
        case .checking: return "checking"
        case .generic, .file: return "generic"
        case .busy: return "busy"
        case .blocked: return "blocked"
        case .missing: return "missing"
        case .server: return "server"
        case .offline: return "offline"
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
        controller.phoneVideoView = v
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
